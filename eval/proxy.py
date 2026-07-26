"""Personal-vocabulary benchmark, proxy speaker.  [Track A]

**This is not dysarthric speech and must never be presented as such.** It is
synthesised proxy speech, degraded until the recogniser fails, and it measures
one thing only: when a speaker's own vocabulary is mis-heard, does the
correction loop recover it?

Why this exists
---------------
TORGO cannot answer that question. Its prompts are phonetically-balanced
TIMIT-style sentences ("she had your dark suit in greasy wash water"), so the
vocabulary a correction stream teaches is ordinary English the recogniser
already gets right. Measured on TORGO, a previously-corrected word is
mis-recognised in 0-3% of held-out utterances depending on speaker, which caps
any achievable WER gain at well under one point — below the noise of the
measurement. A flat TORGO curve is therefore the *expected* result, and says
nothing either way about the mechanism.

Real users of an AAC system do not speak TIMIT sentences. They say the names
of their medications, their carers, their family, their street. Those words
are rare, are exactly what a general recogniser gets wrong, and are exactly
what a personal vocabulary can supply. This benchmark constructs that
situation explicitly, in the standard contextual-biasing style: alongside
overall WER it reports **R-WER**, word error rate restricted to the personal
terms, which is where the claimed effect lives.

Honest limitations, to state in the writeup:
  * synthetic speech across four voices, not a person with dysarthria;
  * degradation is acoustic (noise, level, tempo, muffling), not articulatory;
  * sentences were written to contain personal vocabulary, so the opportunity
    rate is high by construction. That is the point — it isolates the
    mechanism — but it is not an estimate of real-world gain.

One observed effect worth reporting rather than hiding: the vocabulary
saturates at 12 corrections (there are only 12 terms), so later checkpoints
differ *only* in the three-utterance conversational context. Accuracy moves
between them, which means context is a double-edged input — it can pull the
reranker toward recently-said words that do not belong in the current
utterance. Vocabulary is the reliable signal here; context is not.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eval.torgo import corpus_wer, normalize, wer  # noqa: E402
from pipeline import asr, rerank  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO_DIR = os.path.join(os.path.dirname(HERE), "data", "proxy")
OUT_PATH = os.path.join(HERE, "proxy_curve.json")

#: The speaker's world: medication, carers, family, places, routine.
PERSONAL_TERMS = [
    "baclofen", "gabapentin", "Gaviscon", "catheter", "physio", "hoist",
    "Nadia", "Okafor", "Wandsworth", "Bryony", "nebuliser", "commode",
]

#: Correction stream — what the speaker says over their first sessions.
STREAM = [
    "Nadia is coming at four for physio",
    "I need my baclofen before the hoist",
    "can you pass me the Gaviscon please",
    "my gabapentin is in the blue box",
    "the catheter bag needs changing",
    "Bryony rang about the appointment",
    "doctor Okafor changed my gabapentin",
    "the hoist sling is in the cupboard",
    "I want to sit on the commode",
    "my nebuliser is not working again",
    "Nadia knows where the baclofen is",
    "we are going to Wandsworth on Friday",
    "the physio said to keep moving",
    "please order more Gaviscon this week",
    "Bryony is bringing the children over",
    "I need the catheter checked today",
    "doctor Okafor is at the Wandsworth clinic",
    "put the nebuliser on the table",
    "the commode needs emptying please",
    "ask Nadia about my baclofen dose",
]

#: Held-out — never corrected, but reuses the speaker's vocabulary.
TEST = [
    "has Nadia collected my baclofen yet",
    "the gabapentin makes me sleepy",
    "I would like some Gaviscon after lunch",
    "tell Bryony the physio is cancelled",
    "the catheter is uncomfortable today",
    "doctor Okafor wants to see me",
    "bring the hoist closer to the bed",
    "my nebuliser needs a new mask",
    "we should leave for Wandsworth early",
    "put the commode by the window",
    "Nadia forgot the gabapentin again",
    "Bryony will drive me to physio",
    "the baclofen helps with the spasms",
    "ask doctor Okafor about the catheter",
    "Nadia is off next week so Bryony helps",
    "I need the hoist before the physio comes",
    "keep the Gaviscon next to the bed",
    "the Wandsworth clinic rang this morning",
    "my commode needs a new seat",
    "does the nebuliser need cleaning today",
]


#: Rotated across utterances so the result is not an artefact of one voice.
#: Two genders and four accents (GB, AU, IE, US).
VOICES = [("Daniel", 205), ("Karen", 195), ("Moira", 200), ("Samantha", 210)]


def _degrade(text: str, path: str, idx: int) -> None:
    """Synthesise and degrade until the recogniser genuinely struggles."""
    voice, rate = VOICES[idx % len(VOICES)]
    aiff = path + ".aiff"
    subprocess.run(
        ["say", "-r", str(rate), "-v", voice, "-o", aiff, text],
        check=True, capture_output=True,
    )
    # Slight per-utterance variation, so the recogniser is not defeated by one
    # fixed filter chain that it might happen to be unusually bad at.
    tempo = 1.12 + 0.03 * (idx % 3)
    cutoff = 2600 + 150 * (idx % 3)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", aiff,
         "-af", f"volume=0.30,atempo={tempo:.2f},lowpass=f={cutoff},"
                "aresample=16000,highpass=f=180",
         "-ar", "16000", "-ac", "1", path],
        check=True, capture_output=True,
    )
    os.remove(aiff)


def _mix_noise(path: str) -> None:
    noisy = path + ".n.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", path,
         "-f", "lavfi", "-i", "anoisesrc=c=pink:a=0.045",
         "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first",
         "-ar", "16000", "-ac", "1", noisy],
        check=True, capture_output=True,
    )
    os.replace(noisy, path)


def build_audio(force: bool = False) -> dict[str, str]:
    os.makedirs(AUDIO_DIR, exist_ok=True)
    paths = {}
    for i, text in enumerate(STREAM + TEST):
        p = os.path.join(AUDIO_DIR, f"u{i:03d}.wav")
        if force or not os.path.exists(p):
            _degrade(text, p, i)
            _mix_noise(p)
        paths[text] = p
    return paths


def rare_wer(pairs: list[tuple[str, str]], terms: set[str]) -> tuple[float, int]:
    """Error rate restricted to personal terms present in the reference.

    A term counts as correct only if it appears in the hypothesis. This is the
    contextual-biasing metric: overall WER dilutes a handful of rare words
    among many common ones, and rare words are the entire point.
    """
    hits = total = 0
    for ref, hyp in pairs:
        hw = set(normalize(hyp).split())
        for w in normalize(ref).split():
            if w in terms:
                total += 1
                hits += 1 if w in hw else 0
    return ((total - hits) / total if total else 0.0), total


def main() -> None:
    terms = {normalize(t) for t in PERSONAL_TERMS}
    print(f"backend={asr.BACKEND} rerank={rerank.MODEL}")
    print("synthesising proxy audio...")
    paths = build_audio(force="--rebuild" in sys.argv)

    print("transcribing held-out set...")
    cands = {t: asr.transcribe(paths[t]) for t in TEST}

    baseline_pairs = [(t, cands[t][0]) for t in TEST]
    base_wer = corpus_wer(baseline_pairs)
    base_rwer, n_terms = rare_wer(baseline_pairs, terms)
    print(f"baseline: WER={base_wer:.3f}  R-WER={base_rwer:.3f}  "
          f"({n_terms} personal-term tokens in held-out)")

    points = []
    for cp in range(0, len(STREAM) + 1, 4):
        vocab_counts: dict[str, int] = {}
        for u in STREAM[:cp]:
            for w in normalize(u).split():
                if w in terms:
                    vocab_counts[w] = vocab_counts.get(w, 0) + 1
        vocab = [w for w, _ in sorted(vocab_counts.items(), key=lambda kv: -kv[1])]
        context = STREAM[max(0, cp - 3) : cp]

        pairs = [(t, rerank.rerank(cands[t], vocab, context)) for t in TEST]
        w = corpus_wer(pairs)
        rw, _ = rare_wer(pairs, terms)
        points.append(
            {"corrections": cp, "vocab": len(vocab), "wer": round(w, 4),
             "rare_wer": round(rw, 4)}
        )
        print(f"  {cp:3d} corrections  vocab={len(vocab):2d}  "
              f"WER={w:.3f}  R-WER={rw:.3f}")

    out = {
        "benchmark": "personal-vocabulary, proxy speaker (synthetic)",
        "voices": [v for v, _ in VOICES],
        "disclaimer": (
            "Synthesised proxy speech degraded acoustically. NOT dysarthric "
            "speech. Isolates whether personal vocabulary is recoverable; "
            "not an estimate of real-world gain."
        ),
        "asr_backend": asr.BACKEND,
        "rerank_model": rerank.MODEL,
        "personal_terms": PERSONAL_TERMS,
        "stream_n": len(STREAM),
        "test_n": len(TEST),
        "baseline_wer": round(base_wer, 4),
        "baseline_rare_wer": round(base_rwer, 4),
        "points": points,
    }
    with open(OUT_PATH, "w") as f:
        json.dump(out, f, indent=1)
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
