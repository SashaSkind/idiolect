"""Regenerate the bundled demo clips from a local TORGO copy.  [Track A]

TORGO is licensed for academic/non-profit use and must not be redistributed,
so the demo clips are NOT in this repository. Download TORGO yourself into
data/torgo/, then run this to populate assets/samples/.

    python3 eval/make_samples.py

Without it the "try a real dysarthric voice" button in the UI has nothing to
play; everything else works unchanged.
"""

from __future__ import annotations

import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eval.torgo import load_utterances  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, "assets", "samples")


def main() -> None:
    utts = load_utterances()
    if not utts:
        sys.exit("no TORGO utterances found — populate data/torgo/ first")
    os.makedirs(DEST, exist_ok=True)

    # M01 first: severe dysarthria like F01, but 86 sentence utterances
    # against F01's 19, and the recogniser fails on it in a more instructive
    # way (0.64 WER of near-misses like "clings" -> "clinks", against F01's
    # 0.81 where candidates often collapse to something unrelated).
    picks = [u for u in utts if u.speaker == "M01"][:3]
    picks += [u for u in utts if u.speaker == "F01"][:2]
    picks += [u for u in utts if u.speaker == "F03"][:1]

    manifest = []
    for i, u in enumerate(picks):
        dst = os.path.join(DEST, f"{u.speaker.lower()}_{i}.wav")
        shutil.copy(u.audio, dst)
        manifest.append({"path": os.path.relpath(dst, ROOT),
                         "speaker": u.speaker, "text": u.text})
        print(f"  {os.path.relpath(dst, ROOT)}  [{u.speaker}] {u.text[:44]}")

    with open(os.path.join(DEST, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    print(f"\nwrote {len(manifest)} clips to assets/samples/")


if __name__ == "__main__":
    main()
