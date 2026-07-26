"""Where does personalisation actually help?  [Track A]

Sweeps how badly the audio is degraded and measures the *gain* from personal
vocabulary at each level. Answers a question that matters both for the demo
and for the writeup: harder input does not automatically mean more to gain.

The intuition is that a weaker starting point leaves more headroom. That turns
out to be wrong past a threshold, and the reason is visible in the
transcripts. Personal vocabulary can only repair an error that still carries
evidence of the original word:

    baclofen -> "battle fan"     recoverable, a near-miss
    Gaviscon -> "tablets"        unrecoverable, an unrelated real word

Below the threshold the recogniser mangles the term; above it, the recogniser
replaces it with something confident and unrelated, and the information is
simply gone. No reranker, prompt or dictionary can invent it back.

Output: ``eval/difficulty.json``.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eval.proxy import (  # noqa: E402
    PERSONAL_TERMS,
    STREAM,
    TEST,
    VOICES,
    rare_wer,
)
from eval.torgo import corpus_wer, normalize  # noqa: E402
from pipeline import asr, rerank  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "difficulty.json")
WORK = os.path.join(os.path.dirname(HERE), "data", "difficulty")

#: (label, volume, tempo, lowpass, pink-noise amplitude)
LEVELS = [
    ("mild", 0.40, 1.05, 3400, 0.030),
    ("moderate", 0.30, 1.16, 2700, 0.045),
    ("hard", 0.26, 1.25, 2200, 0.060),
    ("severe", 0.22, 1.35, 1900, 0.075),
    ("extreme", 0.17, 1.48, 1550, 0.095),
]


def build(text: str, path: str, idx: int, cfg) -> None:
    _, vol, tempo, lp, noise = cfg
    voice, rate = VOICES[idx % len(VOICES)]
    aiff = path + ".aiff"
    subprocess.run(["say", "-r", str(rate), "-v", voice, "-o", aiff, text],
                   check=True, capture_output=True)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", aiff,
         "-af", f"volume={vol},atempo={tempo},lowpass=f={lp},"
                "highpass=f=300,aresample=16000",
         "-ar", "16000", "-ac", "1", path],
        check=True, capture_output=True)
    os.remove(aiff)
    tmp = path + ".n.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", path,
         "-f", "lavfi", "-i", f"anoisesrc=c=pink:a={noise}",
         "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first",
         "-ar", "16000", "-ac", "1", tmp],
        check=True, capture_output=True)
    os.replace(tmp, path)


def main() -> None:
    os.makedirs(WORK, exist_ok=True)
    terms = {normalize(t) for t in PERSONAL_TERMS}

    vocab_counts: dict[str, int] = {}
    for u in STREAM:
        for w in normalize(u).split():
            if w in terms:
                vocab_counts[w] = vocab_counts.get(w, 0) + 1
    vocab = [w for w, _ in sorted(vocab_counts.items(), key=lambda kv: -kv[1])]

    results = []
    for cfg in LEVELS:
        label = cfg[0]
        paths = {}
        for i, text in enumerate(TEST):
            p = os.path.join(WORK, f"{label}_{i:03d}.wav")
            if not os.path.exists(p):
                build(text, p, i, cfg)
            paths[text] = p

        base_pairs, pers_pairs = [], []
        for t in TEST:
            cands = asr.transcribe(paths[t])
            base_pairs.append((t, cands[0]))
            pers_pairs.append((t, rerank.rerank(cands, vocab, [])))

        b_wer, p_wer = corpus_wer(base_pairs), corpus_wer(pers_pairs)
        b_rw, _ = rare_wer(base_pairs, terms)
        p_rw, _ = rare_wer(pers_pairs, terms)
        rel = (b_rw - p_rw) / b_rw if b_rw else 0.0
        results.append({
            "level": label,
            "baseline_wer": round(b_wer, 4),
            "personalised_wer": round(p_wer, 4),
            "baseline_rare_wer": round(b_rw, 4),
            "personalised_rare_wer": round(p_rw, 4),
            "rare_wer_gain_relative": round(rel, 4),
        })
        print(f"  {label:9s} baseline WER={b_wer:.3f}  "
              f"R-WER {b_rw:.3f} -> {p_rw:.3f}  gain={rel * 100:+.0f}%")

    best = max(results, key=lambda r: r["rare_wer_gain_relative"])
    payload = {
        "note": (
            "Gain from personal vocabulary against input difficulty. Harder "
            "input does not mean more to gain: past a threshold the recogniser "
            "substitutes an unrelated real word ('Gaviscon' -> 'tablets') "
            "rather than a near-miss ('baclofen' -> 'battle fan'), and the "
            "evidence needed to repair it is gone."
        ),
        "best_level": best["level"],
        "levels": results,
    }
    with open(OUT, "w") as f:
        json.dump(payload, f, indent=1)
    print(f"\nbest: {best['level']} "
          f"({best['rare_wer_gain_relative'] * 100:+.0f}% R-WER)")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
