"""Verify the live demo flow, and find words that reliably carry it.  [Track A]

The demo is:

    1. say a sentence containing a personal word  -> recogniser mangles it
    2. correct it once                            -> word enters the vocabulary
    3. say a DIFFERENT sentence using that word   -> it comes back right,
                                                     with no correction needed

Step 3 is the whole pitch, and it only lands if the word behaves: the
recogniser has to get it wrong in step 1 (or there is nothing to correct) and
right in step 3 (or the demo falls flat). This script tests candidate words
through the real pipeline and reports which ones do both.

Run before demoing:

    python3 eval/demo_flow.py

Words are synthesised here, so treat the shortlist as a starting point and
rehearse with your own voice — but a word that fails here will almost
certainly fail live.
"""

from __future__ import annotations

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eval.torgo import normalize  # noqa: E402
from pipeline import asr, rerank  # noqa: E402

WORK = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "demo"
)

#: (word, first utterance, second utterance in a different context)
CANDIDATES = [
    ("baclofen", "I need my baclofen", "has the baclofen arrived yet"),
    ("gabapentin", "my gabapentin is finished", "bring me the gabapentin please"),
    ("Gaviscon", "pass me the Gaviscon", "the Gaviscon is by the bed"),
    ("nebuliser", "my nebuliser is broken", "clean the nebuliser tonight"),
    ("Wandsworth", "we are going to Wandsworth", "the Wandsworth clinic called"),
    ("Bryony", "Bryony is coming over", "tell Bryony I am ready"),
    ("Okafor", "doctor Okafor changed it", "ask doctor Okafor about it"),
    ("catheter", "the catheter hurts", "change the catheter please"),
    ("physio", "physio is at four", "I am tired after physio"),
    ("commode", "I need the commode", "put the commode over there"),
    ("Siobhan", "Siobhan is here", "tell Siobhan I am ready"),
    ("risperidone", "I take risperidone", "the risperidone is finished"),
    ("clonazepam", "my clonazepam is low", "order more clonazepam"),
    ("Zopiclone", "I need Zopiclone", "the Zopiclone helps me sleep"),
    ("Aoife", "Aoife called me", "ask Aoife about it"),
    ("ondansetron", "give me ondansetron", "the ondansetron worked"),
    ("Ravensbourne", "we live in Ravensbourne", "the Ravensbourne bus is late"),
    ("Padma", "Padma is my carer", "Padma comes on Tuesday"),
]


def say(text: str, path: str) -> None:
    """Synthesise, mumbled: fast, quiet, muffled — like an unclear speaker."""
    aiff = path + ".aiff"
    subprocess.run(["say", "-r", "215", "-v", "Daniel", "-o", aiff, text],
                   check=True, capture_output=True)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", aiff,
         "-af", "volume=0.34,atempo=1.12,lowpass=f=2600,highpass=f=250,"
                "aresample=16000",
         "-ar", "16000", "-ac", "1", path],
        check=True, capture_output=True)
    os.remove(aiff)


def heard(text: str, word: str) -> bool:
    return normalize(word) in normalize(text).split()


def main() -> None:
    os.makedirs(WORK, exist_ok=True)
    print(f"backend={asr.BACKEND}  rerank={rerank.MODEL}\n")
    print(f"{'word':12s} {'step1 mangled?':15s} {'step3 recovered?':17s} verdict")
    print("-" * 72)

    good, bad = [], []
    for word, first, second in CANDIDATES:
        p1 = os.path.join(WORK, f"{word.lower()}_1.wav")
        p2 = os.path.join(WORK, f"{word.lower()}_2.wav")
        if not os.path.exists(p1):
            say(first, p1)
        if not os.path.exists(p2):
            say(second, p2)

        # Step 1: no vocabulary yet. We WANT this to fail.
        c1 = asr.transcribe(p1)
        out1 = rerank.rerank(c1, [], [])
        mangled = not heard(out1, word)

        # Step 2: the user corrects it -> the word enters the vocabulary.
        # Step 3: a different sentence, same word, vocabulary now present.
        c2 = asr.transcribe(p2)
        cold = rerank.rerank(c2, [], [])          # what it would say untaught
        warm = rerank.rerank(c2, [word], [first])  # what it says having learned
        recovered = heard(warm, word)
        # Only a real demo beat if learning made the difference.
        earned = recovered and not heard(cold, word)

        verdict = "USE" if (mangled and earned) else (
            "weak" if (mangled and recovered) else "skip")
        (good if verdict == "USE" else bad).append(
            (word, first, second, out1, cold, warm))
        print(f"{word:12s} {str(mangled):15s} {str(recovered):17s} {verdict}")

    print("\n" + "=" * 72)
    print("RECOMMENDED for the live demo (mangles untaught, correct once taught):\n")
    for word, first, second, out1, cold, warm in good:
        print(f"  ** {word} **")
        print(f"     1. say: \"{first}\"")
        print(f"        heard -> {out1!r}   <- correct it to '{word}' here")
        print(f"     2. say: \"{second}\"")
        print(f"        untaught -> {cold!r}")
        print(f"        LEARNED  -> {warm!r}")
        print()
    if not good:
        print("  none passed cleanly — see the weak/skip rows above")


if __name__ == "__main__":
    main()
