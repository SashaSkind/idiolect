# Idiolect — project context

Personalised speech recognition for dysarthric speakers. The acoustic model is
fixed; the system adapts by learning the speaker's own vocabulary from their
corrections and using it to rerank/repair ASR candidates.

## Jac

This project is written in Jac. **Always consult `llmdocs-jaseci.txt` for syntax
before writing or editing any `.jac` file. Do not infer Jac syntax from Python
or JavaScript.** Compile early and often with `jac run main.jac`; never let a
large amount of unverified Jac accumulate.

Frontend components are `.cl.jac` files (JSX syntax, Vite under the hood).

## Machine

Mac, Apple Silicon (M3 Pro, 36 GB). MLX and Metal, **never CUDA**.

## The pipeline contract

Track B codes against exactly these two functions. Changing either signature
requires telling the other person out loud.

```python
from pipeline.asr import transcribe      # (audio_path: str) -> list[str]
from pipeline.rerank import rerank       # (candidates, vocab, context) -> str
```

Both are implemented and working. Neither ever raises in normal use:
`transcribe` always returns ≥1 candidate; `rerank` falls back to `candidates[0]`
if Ollama is unreachable.

Call `pipeline.asr.warmup()` and `pipeline.rerank.warmup()` at server start so
the first user interaction isn't slow.

## Models

| Role | **In use** | Notes |
|---|---|---|
| ASR | **`mlx-community/parakeet-tdt-0.6b-v3`** | as planned; auto-selected when weights present |
| Rerank LLM | **`llama3.1:8b` via Ollama** | replaces `gemma4:e4b` |

**Track B:** byLLM must point at `ollama/llama3.1:8b`, *not* `ollama/gemma-4-e4b`
— the latter is not even a real Ollama tag (the correct one is `gemma4:e4b`,
9.6 GB). `llama3.1:8b` was already on disk and is validated; treat gemma4 as an
optional swap, not a dependency.

Whisper (`whisper-small-mlx`) is fully implemented as a fallback backend.
Force either with `IDIOLECT_ASR_BACKEND=parakeet|whisper`.

Warm latency, measured: **ASR 0.27 s + rerank 1.4 s ≈ 1.6 s** per utterance.
Call `asr.warmup()` and `rerank.warmup()` at server start — cold ASR is ~3 s
and a cold Ollama load is ~6 s.

Everything runs locally. Nothing goes to a hosted API — worth stating in the
writeup, since the demo vocabulary is medical.

## Evidence

See `eval/FINDINGS.md` before writing any claim about accuracy. Short version:
TORGO shows **no gain** (and we explain why — its prompts contain almost no
personal vocabulary); the proxy benchmark shows **R-WER −39%**. Do not claim a
TORGO improvement.

## Ollama

Must be running. Always pass `keep_alive: -1` on requests (the pipeline does) so
the model never unloads and cold-starts in front of judges.

## Timing

All hacking must occur between 10:45 AM and 7:15 PM today; commit timestamps
are checked.
