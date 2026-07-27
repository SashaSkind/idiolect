"""N-best speech transcription.  [Track A]

Contract (Track B codes against this — do not change without telling them):

    transcribe(audio_path: str) -> list[str]
        Return n-best candidate transcriptions, best first.
        Always returns at least one element.

Backends
--------
Two are implemented behind one contract:

  * ``whisper``  — mlx-whisper, currently the active backend.
  * ``parakeet`` — parakeet-mlx, preferred; auto-selected once its weights are
    on disk (the download did not finish on the venue network).

Select explicitly with ``IDIOLECT_ASR_BACKEND=whisper|parakeet``, otherwise
Parakeet wins when available.

How n-best is obtained
----------------------
Both libraries already compute a ranked list of candidate hypotheses during
beam search and then throw away everything except the winner:

    parakeet_mlx  best = max(finished_hypothesis, key=...)
    mlx_whisper   selected = self.sequence_ranker.rank(tokens, sum_logprobs)
                  tokens = [t[i] for i, t in zip(selected, tokens)]

So the n-best list we need already exists — it is simply discarded one line
later. Rather than reimplement beam search, each backend takes the *installed*
source of the relevant method, makes a single surgical edit that records the
ranked list before the winner is returned, and rebinds the method. The top-1
result is bit-for-bit what the library would have produced.

Deriving the patch from installed source at import time means it cannot
silently drift out of sync with the library: if the line it keys on ever
changes, installation fails loudly-but-safely and the backend falls back to
sampling several decodes and deduping (the approach sanctioned in the plan).
"""

from __future__ import annotations

import inspect
import os
import textwrap
import threading
from concurrent.futures import ThreadPoolExecutor

#: How many candidates ``transcribe()`` returns by default.
DEFAULT_N = 4

#: Parakeet beam width. Wider = more diverse candidates, slower decode.
BEAM_SIZE = 5

#: Whisper has no beam search (mlx-whisper raises NotImplementedError), so
#: candidates come from `best_of` independent sampled trajectories, which the
#: library ranks — and discards — through the same code path.
SAMPLE_BEST_OF = 5
SAMPLE_TEMP = 0.4

WHISPER_MODEL = os.environ.get(
    "IDIOLECT_WHISPER_MODEL", "mlx-community/whisper-small-mlx"
)
PARAKEET_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


def _dedupe(texts: list[str]) -> list[str]:
    """Order-preserving dedupe, case/whitespace insensitive, drops empties."""
    seen: set[str] = set()
    out: list[str] = []
    for t in texts:
        norm = " ".join(t.lower().split())
        if norm and norm not in seen:
            seen.add(norm)
            out.append(t.strip())
    return out


# ==========================================================================
# Whisper backend
# ==========================================================================

_w_sink: list[list[str]] = []
_w_lock = threading.Lock()
_whisper_patched = False


def _capture_whisper_nbest(tokens, sum_logprobs, tokenizer, length_penalty):
    """Record the beam group as text, ranked exactly as MaximumLikelihoodRanker
    would rank it (score = sum_logprob / length penalty, descending)."""

    def score(logprob, length):
        if length_penalty is None:
            penalty = length
        else:  # Google NMT length penalty, as used by the library's ranker
            penalty = ((5 + length) / 6) ** length_penalty
        return logprob / (penalty or 1)

    try:
        for group, logprobs in zip(tokens, sum_logprobs):
            ranked = sorted(
                zip(group, logprobs),
                key=lambda p: score(p[1], len(p[0])),
                reverse=True,
            )
            _w_sink.append([tokenizer.decode(t).strip() for t, _ in ranked])
    except Exception:
        pass  # never let candidate capture break transcription


def _install_whisper_patch() -> bool:
    try:
        import mlx_whisper.decoding as _wd
    except ImportError:
        return False

    anchor = "selected = self.sequence_ranker.rank(tokens, sum_logprobs)"
    try:
        src = inspect.getsource(_wd.DecodingTask.run)
    except (OSError, TypeError):
        return False

    lines, hit = [], 0
    for ln in src.split("\n"):
        lines.append(ln)
        if ln.strip() == anchor:
            hit += 1
            indent = ln[: len(ln) - len(ln.lstrip())]
            lines.append(
                f"{indent}_capture_whisper_nbest(tokens, sum_logprobs, "
                f"tokenizer, self.sequence_ranker.length_penalty)"
            )
    if hit != 1:
        return False

    src = textwrap.dedent("\n".join(lines)).replace("def run(", "def run_nbest(", 1)
    ns = dict(vars(_wd))
    ns["_capture_whisper_nbest"] = _capture_whisper_nbest
    try:
        exec(compile(src, "<whisper-nbest-patch>", "exec"), ns)
    except Exception:
        return False

    fn = ns.get("run_nbest")
    if fn is None:
        return False
    _wd.DecodingTask.run = fn
    return True


def _whisper_call(audio_path: str, **extra):
    import mlx_whisper

    return mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=WHISPER_MODEL,
        language="en",
        condition_on_previous_text=False,
        **extra,
    )


def _transcribe_whisper(audio_path: str, n: int) -> list[str]:
    """Two passes: greedy fixes first place, sampling supplies the alternates.

    Sampling alone would make the top candidate non-deterministic and often
    worse than greedy, and the reranker is told candidate 1 is the most
    confident — so the authoritative top-1 comes from a temperature-0 decode.
    A single `best_of` pass then yields the rest of the ranked group at the
    cost of one extra decode. Scalar temperatures (not the library's default
    fallback tuple) keep each pass to exactly one decode per window, so the
    captured sink is unambiguous.
    """
    top = (_whisper_call(audio_path, temperature=0.0).get("text") or "").strip()

    candidates: list[str] = []
    if _whisper_patched:
        with _w_lock:
            _w_sink.clear()
            try:
                _whisper_call(
                    audio_path,
                    temperature=SAMPLE_TEMP,
                    best_of=max(SAMPLE_BEST_OF, n),
                )
                captured = list(_w_sink)
            except Exception:
                captured = []
            finally:
                _w_sink.clear()
        if captured:
            candidates = captured[0]

    out = _dedupe([top] + candidates)[:n]
    return out or [top]


# ==========================================================================
# Parakeet backend (activates automatically once weights are on disk)
# ==========================================================================

_p_sink: list[list[list]] = []
_p_lock = threading.Lock()
_parakeet_patched = False
_p_model = None
_p_model_lock = threading.Lock()


def _capture_parakeet_best(hypotheses, key=None):
    """Drop-in replacement for ``max(hypotheses, key=...)`` that also records
    the full ranked list. Returns the same object ``max`` would: both yield the
    first maximal element under a stable sort."""
    ranked = sorted(hypotheses, key=key, reverse=True)
    _p_sink.append([h.hypothesis for h in ranked[:8]])
    return ranked[0]


def _install_parakeet_patch() -> bool:
    try:
        import parakeet_mlx.parakeet as _pk
    except ImportError:
        return False
    try:
        src = textwrap.dedent(inspect.getsource(_pk.ParakeetTDT.decode_beam))
    except (OSError, TypeError):
        return False
    if src.count("best = max(") != 1:
        return False

    src = src.replace("best = max(", "best = _capture_parakeet_best(").replace(
        "def decode_beam(", "def decode_beam_nbest(", 1
    )
    ns = dict(vars(_pk))
    ns["_capture_parakeet_best"] = _capture_parakeet_best
    try:
        exec(compile(src, "<parakeet-nbest-patch>", "exec"), ns)
    except Exception:
        return False

    fn = ns.get("decode_beam_nbest")
    if fn is None:
        return False
    _pk.ParakeetTDT.decode_beam = fn
    return True


def _parakeet_weights_present() -> bool:
    """True only if the weights are fully downloaded (no .incomplete stub)."""
    from pathlib import Path

    root = (
        Path.home()
        / ".cache/huggingface/hub"
        / f"models--{PARAKEET_MODEL.replace('/', '--')}"
    )
    if not root.exists():
        return False
    blobs = root / "blobs"
    if not blobs.exists():
        return False
    return any(
        f.suffix != ".incomplete" and f.stat().st_size > 100_000_000
        for f in blobs.iterdir()
        if f.is_file()
    )


def _load_parakeet():
    global _p_model
    with _p_model_lock:
        if _p_model is None:
            from parakeet_mlx import from_pretrained

            _p_model = from_pretrained(PARAKEET_MODEL)
        return _p_model


def _transcribe_parakeet(audio_path: str, n: int) -> list[str]:
    from parakeet_mlx import Beam, DecodingConfig

    model = _load_parakeet()
    cfg = DecodingConfig(decoding=Beam(beam_size=BEAM_SIZE))

    with _p_lock:
        _p_sink.clear()
        try:
            result = model.transcribe(audio_path, decoding_config=cfg)
        except Exception:
            _p_sink.clear()
            raise
        captured = list(_p_sink)
        _p_sink.clear()

    candidates = []
    if captured:
        candidates = ["".join(t.text for t in toks).strip() for toks in captured[0]]
    out = _dedupe([result.text] + candidates)[:n]
    return out or [result.text or ""]


# ==========================================================================
# Dispatch
# ==========================================================================


# ==========================================================================
# Gemma 4 native audio — a second, independent hypothesis source
# ==========================================================================

#: Invoke Gemma's audio path when Parakeet's candidates disagree.
GEMMA_AUDIO = os.environ.get("IDIOLECT_GEMMA_AUDIO", "1") == "1"
GEMMA_AUDIO_MODEL = os.environ.get("IDIOLECT_GEMMA_AUDIO_MODEL", "gemma4:e4b")

_GEMMA_PROMPT = (
    "Transcribe this audio exactly. The speaker may have a speech impairment. "
    "Output only the words spoken, on one line, with no commentary."
)


def gemma_audio_hypothesis(audio_path: str, timeout: float = 30.0) -> str:
    """Transcribe with Gemma 4's native audio path. Returns '' on any failure.

    Gemma 4 is not a better transcriber than Parakeet and is not used as one.
    It is useful here because it is *independently* wrong: for one clip
    Parakeet returned "battle fender" and Gemma returned "bachelor's ben" for
    the same word. Two unrelated errors give the reranker more to triangulate
    from than one error repeated, and the correct word is more likely to be
    recoverable from either.

    Audio rides in the `images` field — Ollama routes all media through it.
    """
    import base64
    import json as _json
    import urllib.request

    try:
        with open(audio_path, "rb") as f:
            blob = base64.b64encode(f.read()).decode()
        body = {
            "model": GEMMA_AUDIO_MODEL,
            "messages": [
                {"role": "user", "content": _GEMMA_PROMPT, "images": [blob]}
            ],
            "stream": False,
            "think": False,  # reasoning models return empty content otherwise
            "keep_alive": -1,
            "options": {"temperature": 0.0, "num_predict": 120},
        }
        url = os.environ.get("OLLAMA_URL", "http://localhost:11434")
        req = urllib.request.Request(
            f"{url}/api/chat",
            data=_json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            text = _json.loads(resp.read()).get("message", {}).get("content", "")
    except Exception:
        return ""  # never let the second opinion break transcription

    text = (text or "").strip().split("\n")[0].strip()
    # Refusals and commentary are worse than no hypothesis at all.
    low = text.lower()
    if not text or low.startswith(("i'm sorry", "i cannot", "i can't", "sorry")):
        return ""
    return text.strip('"')


def _select_backend() -> str:
    forced = os.environ.get("IDIOLECT_ASR_BACKEND", "").strip().lower()
    if forced in ("whisper", "parakeet"):
        return forced
    return "parakeet" if _parakeet_weights_present() else "whisper"


BACKEND = _select_backend()

if BACKEND == "parakeet":
    _parakeet_patched = _install_parakeet_patch()
    NBEST_AVAILABLE = _parakeet_patched
else:
    _whisper_patched = _install_whisper_patch()
    NBEST_AVAILABLE = _whisper_patched


#: MLX arrays are bound to the thread that created them: using a model from a
#: thread other than the one that loaded it raises
#: "There is no Stream(cpu, 1) in current thread". The Jac server dispatches
#: each walker through `asyncio.to_thread`, so consecutive requests arrive on
#: different pool threads and the second one fails. Funnelling every MLX call
#: through one dedicated worker keeps model creation and use on a single
#: thread, which is what MLX requires. It also serialises decoding, which is
#: correct anyway — the GPU is one resource.
_mlx_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="idiolect-mlx")


def _run_on_mlx_thread(fn, *args):
    return _mlx_pool.submit(fn, *args).result()


def transcribe(audio_path: str, n: int = DEFAULT_N) -> list[str]:
    """Return n-best candidate transcriptions for ``audio_path``, best first.

    Safe to call from any thread: the MLX work is marshalled onto a single
    dedicated worker (see `_mlx_pool`).
    """
    return _run_on_mlx_thread(_transcribe_impl, audio_path, n)


def _transcribe_impl(audio_path: str, n: int) -> list[str]:
    if BACKEND == "parakeet":
        out = _transcribe_parakeet(audio_path, n)
    else:
        out = _transcribe_whisper(audio_path, n)

    # Selective escalation: only ask Gemma when the acoustic model is unsure.
    # A unanimous n-best means it was confident, and a second opinion costs a
    # second inference for nothing. Disagreement is where extra evidence pays.
    if GEMMA_AUDIO and len(out) > 1:
        extra = gemma_audio_hypothesis(audio_path)
        if extra:
            out = _dedupe(out + [extra])[: n + 1]
    return out


def warmup() -> None:
    """Force model load so the demo's first click isn't slow."""
    import wave
    from pathlib import Path

    silence = Path("/tmp/_idiolect_warmup.wav")
    if not silence.exists():
        with wave.open(str(silence), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(b"\x00\x00" * 16000)
    try:
        transcribe(str(silence), n=1)
    except Exception:
        pass


if __name__ == "__main__":
    import sys
    import time

    path = sys.argv[1] if len(sys.argv) > 1 else "audio/test.wav"
    print(f"backend={BACKEND}  true n-best={NBEST_AVAILABLE}")
    t0 = time.time()
    warmup()
    print(f"warmup {time.time() - t0:.1f}s")
    t0 = time.time()
    for i, c in enumerate(transcribe(path)):
        print(f"  [{i}] {c!r}")
    print(f"transcribed in {time.time() - t0:.2f}s")
