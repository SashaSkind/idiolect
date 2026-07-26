"""Track A integration point for contextual reranking."""

try:
    from .real_rerank import rerank
except ImportError:
    from .stubs import rerank

__all__ = ["rerank"]

