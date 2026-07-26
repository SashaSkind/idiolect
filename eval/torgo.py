"""TORGO data preparation + WER.  [Track A]

TORGO (Rudzicz et al., 2012) — dysarthric speech from speakers with cerebral
palsy or ALS. Academic use only; cited in the README. Audio is gitignored.

Layout on disk::

    data/torgo/<SPEAKER>/Session<N>/prompts/NNNN.txt      prompt text
                                   /wav_headMic/NNNN.wav  close mic
                                   /wav_arrayMic/NNNN.wav array mic

Two filtering decisions, both from the build plan and both load-bearing:

1. **Sentences only.** Bracketed instructions ("[say Ah-P-Eee repeatedly]") and
   isolated single words are dropped. Isolated words starve the context layer
   and are the hardest category even for challenge-winning systems; including
   them would measure something other than what we claim to improve.

2. **Split by prompt text, never randomly.** TORGO repeats the same prompts
   across sessions, so a random split puts the same sentence in both the
   correction stream and the held-out set. That leaks the exact vocabulary
   we're claiming to learn and inflates the result. Splitting on the
   normalised prompt string guarantees a test sentence is never one the
   system has already been corrected on.
"""

from __future__ import annotations

import glob
import json
import os
import re
from dataclasses import asdict, dataclass

DATA_ROOT = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "torgo")

#: Minimum words for a prompt to count as a sentence.
MIN_WORDS = 4

_PUNCT = re.compile(r"[^a-z0-9' ]+")
_WS = re.compile(r"\s+")


_CONTRACTIONS = {
    "i'm": "i am", "he's": "he is", "she's": "she is", "it's": "it is",
    "that's": "that is", "there's": "there is", "what's": "what is",
    "let's": "let us", "who's": "who is", "here's": "here is",
    "you're": "you are", "we're": "we are", "they're": "they are",
    "i've": "i have", "you've": "you have", "we've": "we have",
    "they've": "they have", "i'll": "i will", "you'll": "you will",
    "he'll": "he will", "she'll": "she will", "we'll": "we will",
    "they'll": "they will", "i'd": "i would", "you'd": "you would",
    "he'd": "he would", "she'd": "she would", "we'd": "we would",
    "they'd": "they would", "don't": "do not", "doesn't": "does not",
    "didn't": "did not", "can't": "cannot", "won't": "will not",
    "isn't": "is not", "aren't": "are not", "wasn't": "was not",
    "weren't": "were not", "hasn't": "has not", "haven't": "have not",
    "hadn't": "had not", "wouldn't": "would not", "couldn't": "could not",
    "shouldn't": "should not", "it'll": "it will",
}

_ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven",
         "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
         "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
_TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
         "eighty", "ninety"]


def _num_to_words(n: int) -> str:
    if n < 20:
        return _ONES[n]
    if n < 100:
        return (_TENS[n // 10] + (" " + _ONES[n % 10] if n % 10 else "")).strip()
    if n < 1000:
        rest = n % 100
        return (_ONES[n // 100] + " hundred" + (" " + _num_to_words(rest) if rest else "")).strip()
    if n < 1000000:
        rest = n % 1000
        return (_num_to_words(n // 1000) + " thousand" + (" " + _num_to_words(rest) if rest else "")).strip()
    return str(n)


def normalize(text: str) -> str:
    """Lowercase, expand contractions and digits, strip punctuation.

    Used for both WER scoring and prompt-identity comparison.

    Digit and contraction expansion matter more than they look: Whisper emits
    "he's nearly 93 years old" where the TORGO prompt reads "he is nearly
    ninety three years old". Scored literally that is four errors out of seven
    words, none of which is a recognition mistake. Without this the baseline
    is penalised for formatting and the personalisation signal is buried in
    noise.
    """
    t = text.lower().replace("-", " ").replace("—", " ")
    for k, v in _CONTRACTIONS.items():
        t = re.sub(rf"\b{re.escape(k)}\b", v, t)
    t = _PUNCT.sub(" ", t)
    t = re.sub(r"\b\d+\b", lambda m: _num_to_words(int(m.group())), t)
    # possessives and residual apostrophes ("brother's" -> "brothers")
    t = t.replace("'", "")
    return _WS.sub(" ", t).strip()


@dataclass
class Utterance:
    speaker: str
    session: str
    uid: str
    audio: str
    text: str  # normalised reference


def _is_sentence(raw: str) -> bool:
    raw = raw.strip()
    if not raw or raw.startswith("["):  # instruction to the participant
        return False
    low = raw.lower()
    # Picture-description stimuli ("input/images/kitchen.jpg"). The participant
    # describes an image spontaneously, so the prompt is NOT a transcript of
    # what they said — there is no reference text to score against.
    if "/" in raw or low.endswith((".jpg", ".png", ".bmp", ".wav")):
        return False
    if low.startswith(("xxx", "input given")):
        return False
    return len(normalize(raw).split()) >= MIN_WORDS


def load_utterances(root: str = DATA_ROOT) -> list[Utterance]:
    """All usable sentence utterances found on disk, deduped by (speaker,text).

    Prefers the head-mounted mic; falls back to the array mic. Repeats of the
    same prompt by the same speaker are collapsed to one recording so that a
    frequently-repeated sentence cannot dominate the evaluation.
    """
    out: list[Utterance] = []
    seen: set[tuple[str, str]] = set()

    for ppath in sorted(glob.glob(os.path.join(root, "*", "Session*", "prompts", "*.txt"))):
        try:
            raw = open(ppath, encoding="utf-8", errors="replace").read().strip()
        except OSError:
            continue
        if not _is_sentence(raw):
            continue

        session_dir = os.path.dirname(os.path.dirname(ppath))
        uid = os.path.basename(ppath)[:-4]
        audio = None
        for mic in ("wav_headMic", "wav_arrayMic"):
            cand = os.path.join(session_dir, mic, uid + ".wav")
            if os.path.exists(cand) and os.path.getsize(cand) > 2000:
                audio = cand
                break
        if audio is None:
            continue

        speaker = os.path.basename(os.path.dirname(session_dir))
        text = normalize(raw)
        if (speaker, text) in seen:
            continue
        seen.add((speaker, text))

        out.append(
            Utterance(
                speaker=speaker,
                session=os.path.basename(session_dir),
                uid=uid,
                audio=audio,
                text=text,
            )
        )
    return out


# --------------------------------------------------------------------------
# splitting
# --------------------------------------------------------------------------


def content_words(text: str, min_len: int = 4) -> set[str]:
    """Words worth learning as personal vocabulary.

    Deliberately crude: long-ish tokens that aren't function words. The point
    is to model what a real correction UI would harvest, not to do linguistics.
    """
    return {w for w in normalize(text).split() if len(w) >= min_len and w not in STOPWORDS}


STOPWORDS = {
    "the", "and", "for", "that", "with", "this", "have", "from", "they", "will",
    "would", "there", "their", "what", "when", "your", "them", "than", "then",
    "been", "were", "into", "some", "more", "very", "just", "over", "also",
    "back", "after", "other", "many", "much", "such", "only", "even", "most",
    "make", "made", "does", "about", "could", "should", "these", "those",
    "which", "while", "where", "because", "before", "being", "under", "again",
}


def split_shared(
    utts: list[Utterance], n_test: int = 25
) -> tuple[list[Utterance], list[Utterance]]:
    """Realistic condition: held-out sentences share vocabulary with the
    correction stream, because people repeat their own words.

    Test sentences are chosen for having the *most* content-word overlap with
    the rest of the corpus, so the correction stream genuinely teaches words
    the test set will need.
    """
    pool = list(utts)
    vocab_all: dict[str, int] = {}
    for u in pool:
        for w in content_words(u.text):
            vocab_all[w] = vocab_all.get(w, 0) + 1

    def overlap(u: Utterance) -> float:
        ws = content_words(u.text)
        if not ws:
            return 0.0
        # words that also occur in at least one *other* utterance
        return sum(1 for w in ws if vocab_all.get(w, 0) > 1) / len(ws)

    ranked = sorted(pool, key=overlap, reverse=True)
    test = ranked[:n_test]
    test_ids = {(u.speaker, u.text) for u in test}
    stream = [u for u in pool if (u.speaker, u.text) not in test_ids]
    return stream, test


def split_unshared(
    utts: list[Utterance], n_test: int = 25
) -> tuple[list[Utterance], list[Utterance]]:
    """Hard condition: held-out sentences whose content words never appear in
    the correction stream. Personalisation cannot help by supplying the exact
    word, so any gain must come from context and phrasing alone.

    Built greedily: take candidate test sentences that share no content word
    with the stream that remains.
    """
    pool = list(utts)
    test: list[Utterance] = []
    test_words: set[str] = set()

    # Prefer sentences with rare words — they're the ones most likely to be
    # isolable from the rest of the corpus.
    freq: dict[str, int] = {}
    for u in pool:
        for w in content_words(u.text):
            freq[w] = freq.get(w, 0) + 1

    def rarity(u: Utterance) -> float:
        ws = content_words(u.text)
        return sum(freq.get(w, 0) for w in ws) / max(1, len(ws))

    for u in sorted(pool, key=rarity):
        if len(test) >= n_test:
            break
        test.append(u)
        test_words |= content_words(u.text)

    test_ids = {(u.speaker, u.text) for u in test}
    stream = [u for u in pool if (u.speaker, u.text) not in test_ids]

    # Enforce the guarantee: drop any stream utterance that would teach a test
    # word. This is what makes the condition genuinely "unshared".
    stream = [u for u in stream if not (content_words(u.text) & test_words)]
    return stream, test


# --------------------------------------------------------------------------
# WER
# --------------------------------------------------------------------------


def wer(reference: str, hypothesis: str) -> tuple[int, int]:
    """Levenshtein word distance. Returns (errors, reference_length)."""
    r = normalize(reference).split()
    h = normalize(hypothesis).split()
    if not r:
        return (len(h), 0)

    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i]
        for j, hw in enumerate(h, 1):
            cur.append(
                prev[j - 1] if rw == hw else 1 + min(prev[j - 1], prev[j], cur[j - 1])
            )
        prev = cur
    return (prev[-1], len(r))


def corpus_wer(pairs: list[tuple[str, str]]) -> float:
    """Aggregate WER over (reference, hypothesis) pairs.

    Errors and lengths are pooled before dividing — averaging per-utterance
    rates would over-weight short sentences.
    """
    errs = total = 0
    for ref, hyp in pairs:
        e, n = wer(ref, hyp)
        errs += e
        total += n
    return errs / total if total else 0.0


if __name__ == "__main__":
    utts = load_utterances()
    print(f"usable sentence utterances: {len(utts)}")
    by_spk: dict[str, int] = {}
    for u in utts:
        by_spk[u.speaker] = by_spk.get(u.speaker, 0) + 1
    print(f"by speaker: {by_spk}")

    for name, fn in (("shared", split_shared), ("unshared", split_unshared)):
        stream, test = fn(utts)
        sw: set[str] = set()
        for u in stream:
            sw |= content_words(u.text)
        tw: set[str] = set()
        for u in test:
            tw |= content_words(u.text)

        print(
            f"\n{name:9s} stream={len(stream):3d} test={len(test):3d} "
            f"test-words-covered-by-stream={len(tw & sw)}/{len(tw)}"
        )
        for u in test[:3]:
            print(f"    test: {u.text[:60]}")

    os.makedirs(os.path.dirname(__file__), exist_ok=True)
    with open(os.path.join(os.path.dirname(__file__), "manifest.json"), "w") as f:
        json.dump([asdict(u) for u in utts], f, indent=1)
    print(f"\nwrote eval/manifest.json ({len(utts)} utterances)")
