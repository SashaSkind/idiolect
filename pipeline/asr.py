"""Track A integration point for speech transcription."""

try:
    from .real_asr import transcribe
except ImportError:
    from .stubs import transcribe

__all__ = ["transcribe"]

