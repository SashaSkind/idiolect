"""The accuracy curve.  [Track A]

Simulates the correction loop offline: feed the correction stream in order,
grow the personal vocabulary as corrections land, and measure WER on a
held-out set every N corrections.

Output: ``eval/curve.json``, cached. **Never computed live during the demo.**

Two conditions are reported, per the build plan:

* **shared**   — held-out sentences share vocabulary with the correction
  stream. Realistic: people repeat their own words. Larger gains.
* **unshared** — held-out sentences share no content word with the stream.
  The hard case, where personalisation cannot simply supply the missing word.
  Smaller gains, reported anyway because hiding it would be dishonest.

The one optimisation that makes this tractable
----------------------------------------------
The acoustic model is *fixed* — it is never adapted. So the n-best candidate
list for a held-out utterance is identical at every checkpoint; only the
reranker's vocabulary changes. Transcribing once and caching the candidates
turns an O(checkpoints x utterances) ASR bill into O(utterances), and is
exactly equivalent to re-running it each time.
"""

from __future__ import annotations

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eval.torgo import (  # noqa: E402
    Utterance,
    content_words,
    corpus_wer,
    load_utterances,
    split_shared,
    split_unshared,
)
from pipeline import asr, rerank  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CURVE_PATH = os.path.join(HERE, "curve.json")
CAND_CACHE = os.path.join(HERE, "candidates.json")

#: Evaluate after every this many corrections.
STEP = 10

#: Context window handed to the reranker, in utterances.
CONTEXT = 3


def transcribe_set(utts: list[Utterance], cache: dict) -> dict[str, list[str]]:
    """N-best candidates per utterance, cached on disk across runs."""
    out = {}
    todo = [u for u in utts if u.audio not in cache]
    if todo:
        print(f"    transcribing {len(todo)} utterances "
              f"({len(utts) - len(todo)} cached)...")
    for i, u in enumerate(utts, 1):
        if u.audio not in cache:
            t0 = time.time()
            try:
                cache[u.audio] = asr.transcribe(u.audio)
            except Exception as e:
                print(f"      ! {u.uid}: {e}")
                cache[u.audio] = [""]
            if i % 5 == 0 or i == len(utts):
                print(f"      {i}/{len(utts)}  ({time.time() - t0:.1f}s last)")
        out[u.audio] = cache[u.audio]
    return out


def run_condition(
    name: str,
    stream: list[Utterance],
    test: list[Utterance],
    cand_cache: dict,
) -> dict:
    print(f"\n=== {name}: stream={len(stream)} test={len(test)} ===")
    cands = transcribe_set(test, cand_cache)
    _save_cache(cand_cache)

    # Baseline: the ASR's own top-1, no personalisation, no reranking at all.
    baseline = corpus_wer([(u.text, cands[u.audio][0]) for u in test])
    print(f"    baseline (ASR top-1, unpersonalised) WER = {baseline:.3f}")

    def evaluate(vocab: list[str], context: list[str]) -> float:
        pairs = []
        for u in test:
            hyp = rerank.rerank(cands[u.audio], vocab, context)
            pairs.append((u.text, hyp))
        return corpus_wer(pairs)

    points = []
    vocab_counts: dict[str, int] = {}
    context: list[str] = []

    checkpoints = list(range(0, len(stream) + 1, STEP))
    for cp in checkpoints:
        # Grow the vocabulary using corrections [previous checkpoint, cp).
        while len(context) < cp:
            u = stream[len(context)]
            for w in content_words(u.text):
                vocab_counts[w] = vocab_counts.get(w, 0) + 1
            context.append(u.text)

        # Most-corrected terms first — that is what a real vocabulary panel
        # surfaces, and it keeps the prompt inside a sane length.
        vocab = [w for w, _ in sorted(vocab_counts.items(), key=lambda kv: -kv[1])]
        t0 = time.time()
        w = evaluate(vocab, context[-CONTEXT:])
        points.append({"corrections": cp, "wer": round(w, 4), "vocab": len(vocab)})
        print(f"    {cp:3d} corrections  vocab={len(vocab):4d}  "
              f"WER={w:.3f}  ({time.time() - t0:.0f}s)")

    return {
        "baseline_wer": round(baseline, 4),
        "test_n": len(test),
        "stream_n": len(stream),
        "points": points,
    }


def _save_cache(cache: dict) -> None:
    with open(CAND_CACHE, "w") as f:
        json.dump(cache, f)


def main() -> None:
    quick = "--quick" in sys.argv
    utts = load_utterances()
    if not utts:
        sys.exit("no utterances found — is data/torgo populated?")

    # One speaker. This is a *personal* system: the vocabulary it learns
    # belongs to one person, so pooling speakers would both dilute the
    # vocabulary and average over wildly different severities (F01 transcribes
    # at ~0.81 WER, F03 at ~0.20 — pooling them measures neither).
    speaker = os.environ.get("IDIOLECT_SPEAKER", "F03")
    utts = [u for u in utts if u.speaker == speaker]
    if not utts:
        sys.exit(f"no utterances for speaker {speaker}")
    print(f"speaker {speaker}: {len(utts)} sentence utterances")

    cand_cache = {}
    if os.path.exists(CAND_CACHE):
        try:
            cand_cache = json.load(open(CAND_CACHE))
        except Exception:
            cand_cache = {}

    n_test = 8 if quick else 25
    conditions = {}
    for name, fn in (("shared", split_shared), ("unshared", split_unshared)):
        stream, test = fn(utts, n_test=n_test)
        if quick:
            stream = stream[:20]
        conditions[name] = run_condition(name, stream, test, cand_cache)

    speakers = sorted({u.speaker for u in utts})
    out = {
        "generated": time.strftime("%Y-%m-%d %H:%M"),
        "asr_backend": asr.BACKEND,
        "asr_model": asr.WHISPER_MODEL if asr.BACKEND == "whisper" else asr.PARAKEET_MODEL,
        "rerank_model": rerank.MODEL,
        "dataset": "TORGO (Rudzicz et al. 2012)",
        "speaker": speaker,
        "speakers": speakers,
        "utterances": len(utts),
        "step": STEP,
        "conditions": conditions,
    }
    with open(CURVE_PATH, "w") as f:
        json.dump(out, f, indent=1)
    print(f"\nwrote {CURVE_PATH}")


if __name__ == "__main__":
    main()
