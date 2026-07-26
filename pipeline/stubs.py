"""Deterministic demo pipeline used until Track A swaps in real models."""

from __future__ import annotations

from difflib import SequenceMatcher


DEMO_CANDIDATES = [
    ["message chevron about jack lang", "message siobhan about jack lang", "message chevron about jaclang"],
    ["ask chevron whether the jack lang demo is ready", "ask siobhan whether the jaclang demo is ready", "ask siobhan whether the jack lang demo is ready"],
    ["the personalized speech graph is learning", "the personal speech graph is learning", "a personalized speech graph is learning"],
]

_call_count = 0


def transcribe(audio_path: str) -> list[str]:
    """Return realistic deterministic candidates for UI development."""
    del audio_path
    global _call_count
    candidates = DEMO_CANDIDATES[_call_count % len(DEMO_CANDIDATES)]
    _call_count += 1
    return candidates.copy()


def rerank(candidates: list[str], vocab: list[str], context: list[str]) -> str:
    """Bias candidates toward learned vocabulary without requiring an LLM."""
    del context
    if not candidates:
        return ""
    lowered_vocab = [term.lower() for term in vocab]

    def score(candidate: str) -> tuple[int, float]:
        lowered = candidate.lower()
        vocab_hits = sum(1 for term in lowered_vocab if term in lowered)
        baseline_similarity = SequenceMatcher(None, candidates[0], candidate).ratio()
        return vocab_hits, baseline_similarity

    return max(candidates, key=score)

