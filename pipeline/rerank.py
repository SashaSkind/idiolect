"""Personalised reranking of ASR candidates.  [Track A]

Contract (Track B codes against this — do not change without telling them):

    rerank(candidates: list[str], vocab: list[str], context: list[str]) -> str
        Pick or repair the best candidate given the speaker's personal
        vocabulary and their last few utterances. Returns final text.

This is the part that makes the system personal. The acoustic model is fixed
and speaker-independent; everything the system learns about *this* speaker
arrives here, as vocabulary harvested from their past corrections plus the
recent conversation. A candidate list that contains "i need my back looking"
becomes "i need my baclofen" only because 'baclofen' is in their vocabulary.

Runs against a local Ollama. Nothing leaves the machine.
"""

from __future__ import annotations

import difflib
import json
import os
import re
import urllib.error
import urllib.request

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
MODEL = os.environ.get("IDIOLECT_RERANK_MODEL", "llama3.1:8b")

#: How many recent utterances of context to show the model.
CONTEXT_TURNS = 3

#: How many vocabulary terms to include (most relevant first).
MAX_VOCAB = 12

#: Minimum orthographic similarity between a vocabulary term and some span of
#: the candidates before that term is shown to the model at all.
VOCAB_RELEVANCE = 0.6

#: Higher bar for multi-word spans, which are far more prone to false matches.
VOCAB_RELEVANCE_MULTI = 0.7

#: Additional most-corrected terms offered beyond the string-matched ones, so
#: the model can also make semantically-cued repairs.
FREQUENT_VOCAB = 10

#: Similarity required to override a word every candidate agreed on. Set well
#: above observed false friends (~0.75) and below real cases (~0.89).
AGREED_OVERRIDE = 0.85

TIMEOUT = float(os.environ.get("IDIOLECT_RERANK_TIMEOUT", "60"))

#: Token budget for the reply. Must exceed any reasoning preamble the model
#: emits, or the answer never arrives.
NUM_PREDICT = int(os.environ.get("IDIOLECT_RERANK_TOKENS", "300"))

#: Frequent English words. Used only to decide whether a multi-word candidate
#: span is ordinary enough that it should not be overridden by vocabulary.
COMMON_WORDS = set(
    """a about all also am an and any are as at back be because been before
big but by call can come could day did do down each even first for from get
give go good has have he her here him his how i if in into is it its just
know like little long look made make man many may me more most much must my
new no not now of off old on one only or other our out over own people put
said same say see she should so some such take than that the their them then
there these they thing think this those time to too two up us use very want
was way we well went were what when where which while who will with work
would year you your ah oh yeah okay""".split()
)

SYSTEM = (
    "You correct the output of a speech recogniser for a person with "
    "dysarthria. Their speech is hard to transcribe, so the recogniser "
    "returns several guesses and often mangles words that matter to them."
)

INSTRUCTIONS = """\
Choose the guess that best matches what the speaker actually said.

Rules:
- If one guess is already correct, output it exactly as it is.
- If a guess is right except for one or two words, output it with those words
  repaired. Prefer repairs that use a word from their personal vocabulary.
- Personal vocabulary words are words this speaker uses often. A guess that
  is phonetically close to one of them is usually meant to be that word.
- Do not add words, punctuation or capitalisation that no guess supports.
- Do not answer the sentence, explain, or comment on it.

Output the corrected sentence on one line and nothing else."""


def _norm(s: str) -> str:
    """Lowercase, split hyphens, drop punctuation, collapse whitespace."""
    s = s.lower().replace("-", " ").replace("_", " ")
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    return " ".join(s.split())


def _relevant_vocab(candidates: list[str], vocab: list[str], limit: int = 12) -> list[str]:
    """Keep only vocabulary that could plausibly be what a candidate word
    mis-heard.

    Showing the model the speaker's whole vocabulary is actively harmful: given
    forty unrelated words it will assemble them into a fluent sentence that has
    nothing to do with the audio. (Observed: candidate "he slowly kicks a
    slight walk in the open area" became "He skillfully plays upon each organ,
    except for a small walk in the snow" — every injected word came from the
    vocabulary list.)

    A term earns its place only if it is orthographically close to some span
    actually present in the candidates, which is exactly the situation where
    personal vocabulary should win: the recogniser produced a near-miss of a
    word this speaker uses.

    Matching is against *joined spans* of up to three adjacent candidate words,
    not single words, because the characteristic dysarthric ASR failure is one
    spoken word coming back as several: "baclofen" arrives as "back fluff end"
    or "battle of n", which no word-to-word comparison can recover.

    A raw similarity threshold is not enough on its own — "read" scores 0.75
    against "area" and "three" scores 0.75 against "the", both higher than
    "baclofen" scores against "battle of n". The discriminating signal is
    whether the span the term would displace is *implausible*: a multi-word
    join is suspicious and worth overriding, an ordinary single word is not.
    """
    # Only regions where the recogniser is *unsure* may be repaired. A word
    # every candidate agrees on is one the acoustic model was confident about,
    # and overriding it is how personalisation does damage: as the vocabulary
    # grows, the chance that some term fuzzily resembles some confidently-
    # recognised word approaches one, so error rate climbs with vocabulary
    # size. Disagreement between candidates localises the repair to where
    # evidence is genuinely weak.
    agreed = None
    for c in candidates:
        ws = set(_norm(c).split())
        agreed = ws if agreed is None else (agreed & ws)
    agreed = agreed or set()

    spans: dict[str, int] = {}
    agreed_spans: dict[str, bool] = {}
    for c in candidates:
        words = _norm(c).split()
        for k in range(1, 4):
            for i in range(len(words) - k + 1):
                group = words[i : i + k]
                joined = "".join(group)
                if len(joined) <= 2:
                    continue
                if all(w in agreed for w in group):
                    # Every candidate agrees here. Usually leave it alone — but
                    # dysarthric ASR is frequently *confidently* wrong, giving
                    # a unanimous n-best that simply doesn't contain the truth
                    # ("fleecy" -> "fleecey", "swam" -> "swarm"). Refusing to
                    # touch consensus makes those unfixable, so a single token
                    # may still be overridden on a very strong vocabulary
                    # match. The bar is set well above the false friends that
                    # caused trouble ("three"/"the" at 0.75).
                    if k == 1:
                        agreed_spans[joined] = True
                    continue
                # A multi-word span is only a candidate for replacement if it
                # contains something odd. Joining ordinary words manufactures
                # false friends: "in the" -> "inthe" scores 0.7 against
                # "winter", which would inject a word nobody said. Requiring an
                # unusual token keeps "battle of n" and "bak lofen" while
                # dropping "in the" and "the area".
                if k >= 2 and all(w in COMMON_WORDS for w in group):
                    continue
                spans[joined] = max(spans.get(joined, k), k)
    if not spans:
        return []

    scored: list[tuple[float, str]] = []
    for term in vocab:
        t = _norm(term)
        if not t:
            continue
        best = 0.0
        # Consensus override: near-identical to a word every candidate agreed
        # on, i.e. the speaker's known word came back slightly mangled.
        for span in agreed_spans:
            if span == t:
                continue  # already correct in the transcript
            r = difflib.SequenceMatcher(None, t, span).ratio()
            if r >= AGREED_OVERRIDE and r > best:
                best = r
        for span, k in spans.items():
            r = difflib.SequenceMatcher(None, t, span).ratio()
            if r < VOCAB_RELEVANCE:
                continue
            if k >= 2:
                # A word misheard as several ("baclofen" -> "bak lofen",
                # "battle of n") stays close in length to what was said.
                # Requiring that, plus a higher similarity bar, separates real
                # hits (>=0.71) from joined-common-word noise like
                # "winter"/"walkinthe" and "three"/"theopen" (<=0.67).
                length_ratio = abs(len(t) - len(span)) / max(len(t), len(span))
                ok = r >= VOCAB_RELEVANCE_MULTI and length_ratio <= 0.3
            else:
                # a single ordinary word is only overridden on a near-exact
                # match, and never for a short term (too many false friends)
                ok = r >= 0.999 or (r >= 0.8 and len(t) >= 5)
            if ok and r > best:
                best = r
        if best > 0:
            scored.append((best, term))

    scored.sort(key=lambda p: -p[0])
    out = [t for _, t in scored[:limit]]

    # String similarity alone cannot recover a word that was misheard as a
    # *different real word*: truth "with zest upon", candidates "with death
    # upon" / "assess upon" — "zest" resembles neither, yet the sentence makes
    # it obvious. Those cases need the model's semantics, so top vocabulary
    # (passed most-corrected-first) is offered as well.
    #
    # This is only safe because the output guard is strict: whatever the model
    # returns must preserve every word the candidates agreed on and may use no
    # word outside the candidates plus these terms. That rejects the failure
    # this filter originally existed to prevent — the fluent sentence
    # assembled from vocabulary — without also blocking legitimate repairs.
    for term in vocab:
        if len(out) >= limit + FREQUENT_VOCAB:
            break
        if term not in out:
            out.append(term)
    return out


def _build_prompt(candidates: list[str], vocab: list[str], context: list[str]) -> str:
    parts = [SYSTEM, ""]

    if vocab:
        terms = ", ".join(vocab[:MAX_VOCAB])
        parts.append(
            f"Words this speaker uses often, which a guess may have mis-heard: {terms}"
        )
    else:
        parts.append("This speaker's personal vocabulary: (nothing relevant)")

    recent = [c for c in context if c and c.strip()][-CONTEXT_TURNS:]
    if recent:
        parts.append("")
        parts.append("What they said just before:")
        parts.extend(f"- {c.strip()}" for c in recent)

    parts.append("")
    parts.append("Recogniser guesses, most confident first:")
    parts.extend(f"{i}. {c.strip()}" for i, c in enumerate(candidates, 1))
    parts.append("")
    parts.append(INSTRUCTIONS)
    parts.append("")
    parts.append("Corrected sentence:")
    return "\n".join(parts)


def _clean(raw: str) -> str:
    """Strip the ways a chat model dresses up a one-line answer."""
    text = (raw or "").strip()
    if not text:
        return ""

    # First non-empty line only.
    for line in text.split("\n"):
        if line.strip():
            text = line.strip()
            break

    # "Corrected sentence: foo" / "Output: foo"
    text = re.sub(
        r"^(corrected sentence|corrected|output|answer)\s*[:\-]\s*",
        "",
        text,
        flags=re.I,
    )
    # Leading list numbering the model copied from the prompt.
    text = re.sub(r"^\d+\s*[\.\)]\s*", "", text)
    # Wrapping quotes.
    if len(text) >= 2 and text[0] in "\"'“‘" and text[-1] in "\"'”’":
        text = text[1:-1].strip()
    return text.strip()


def _plausible(out: str, candidates: list[str], shown_vocab: list[str]) -> bool:
    """Reject answers that are not a repair of some candidate.

    A legitimate output is one candidate with at most a couple of words swapped
    for vocabulary terms. So we require, against the closest candidate:

    * similar length (a repair does not change how many words were spoken),
    * most words retained from that candidate,
    * every new word explained — either it came from another candidate, or it
      is one of the vocabulary terms we actually showed the model.

    The last rule is what stops the model assembling a fluent sentence out of
    the vocabulary list, which is the failure mode observed in evaluation.
    """
    ow = _norm(out).split()
    if not ow:
        return False

    allowed = {w for c in candidates for w in _norm(c).split()}
    allowed |= {w for t in shown_vocab for w in _norm(t).split()}

    # Words every candidate agreed on must survive: the reranker may resolve
    # disagreements, never overwrite consensus.
    agreed = None
    for c in candidates:
        ws = set(_norm(c).split())
        agreed = ws if agreed is None else (agreed & ws)
    if agreed:
        missing = agreed - set(ow)
        # A consensus word may only disappear if a closely-matching vocabulary
        # term took its place ("fleecey" -> "fleecy"). Anything else is the
        # model rewriting text the recogniser was sure about.
        shown_words = {w for t in shown_vocab for w in _norm(t).split()}
        if len(missing) > 2:
            return False
        for gone in missing:
            if not any(
                w in shown_words
                and difflib.SequenceMatcher(None, gone, w).ratio() >= AGREED_OVERRIDE
                for w in ow
            ):
                return False

    # A vocabulary word that appears in no candidate is being *introduced*, not
    # selected. That is only legitimate when it resembles something the
    # recogniser actually produced — "baclofen" for "backofen". Offering the
    # speaker's frequent terms for semantically-cued repairs otherwise lets the
    # model swap in a word nobody said: "pass me the cup" -> "pass me the
    # straw", "turn on the telly" -> "turn on the Corrie", both drawn straight
    # from the vocabulary list.
    cand_words = {w for c in candidates for w in _norm(c).split()}
    cand_spans = set(cand_words)
    for c in candidates:
        ws = _norm(c).split()
        for k in (2, 3):
            for i in range(len(ws) - k + 1):
                cand_spans.add("".join(ws[i : i + k]))
    for w in ow:
        if w in cand_words:
            continue
        if not any(
            difflib.SequenceMatcher(None, w, span).ratio() >= VOCAB_RELEVANCE
            for span in cand_spans
        ):
            return False

    for c in candidates:
        cw = _norm(c).split()
        if not cw:
            continue
        if abs(len(ow) - len(cw)) > max(2, len(cw) * 0.35):
            continue
        retained = len(set(ow) & set(cw))
        if retained < max(1, int(len(set(cw)) * 0.5)):
            continue
        if any(w not in allowed for w in ow):
            continue
        return True
    return False


def _ollama(prompt: str) -> str:
    payload = json.dumps(
        {
            "model": MODEL,
            "prompt": prompt,
            "stream": False,
            "keep_alive": -1,  # never unload; a cold start mid-demo is fatal
            "options": {
                "temperature": 0.0,
                # Generous: some models (gemma4) emit reasoning before the
                # answer and return an empty response if cut short, which
                # silently degrades every call to "fall back to candidate 1".
                "num_predict": NUM_PREDICT,
                # No stop sequence. "\n\n" looks like an obvious guard against
                # rambling, but a model that opens its reply with a blank line
                # (gemma4 does) then stops instantly and returns "", which
                # degrades silently: every call falls back to candidate 1 and
                # personalisation appears to do nothing at all. _clean() takes
                # the first non-empty line anyway, so this was never needed.
            },
        }
    ).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read()).get("response", "")


def rerank(candidates: list[str], vocab: list[str], context: list[str]) -> str:
    """Pick or repair the best candidate. Never raises; falls back to top-1."""
    candidates = [c for c in (candidates or []) if c and c.strip()]
    if not candidates:
        return ""

    # Unanimous n-best means the acoustic model had no doubt. There is nothing
    # to choose between and no uncertain region to repair, so don't spend an
    # LLM call on it and don't risk changing a correct transcription.
    if len({_norm(c) for c in candidates}) == 1:
        return candidates[0]

    shown = _relevant_vocab(candidates, vocab or [], limit=MAX_VOCAB)
    if len(candidates) == 1 and not shown:
        return candidates[0]  # nothing to choose between, nothing to repair

    try:
        raw = _ollama(_build_prompt(candidates, shown, context or []))
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
        return candidates[0]

    out = _clean(raw)
    if not _plausible(out, candidates, shown):
        return candidates[0]
    return out


def available() -> bool:
    """True if Ollama is up and the rerank model is present."""
    try:
        with urllib.request.urlopen(f"{OLLAMA_URL}/api/tags", timeout=5) as r:
            names = {m["name"] for m in json.loads(r.read()).get("models", [])}
        return MODEL in names
    except Exception:
        return False


def warmup() -> None:
    """Pin the model in memory so the first real rerank is fast."""
    try:
        _ollama("Say OK.")
    except Exception:
        pass


if __name__ == "__main__":
    import time

    print(f"model={MODEL} available={available()}")
    cases = [
        (
            ["i need my back looking", "i need my black often", "i need my bak lofen"],
            ["baclofen", "Gaviscon", "physio"],
            ["I need my medication"],
        ),
        (
            ["can you pass me the cup", "can you pass me the cop"],
            ["cup", "straw"],
            [],
        ),
        (
            ["turn on the telly", "turn on the tally"],
            ["telly", "Corrie"],
            ["what time is it"],
        ),
    ]
    warmup()
    for cands, vocab, ctx in cases:
        t0 = time.time()
        print(f"\n  candidates: {cands}")
        print(f"  vocab:      {vocab}")
        print(f"  -> {rerank(cands, vocab, ctx)!r}  ({time.time() - t0:.2f}s)")
