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

## Models — READ THIS, it differs from the build plan

The venue network runs at ~90–170 KB/s. The models named in the original plan
could not be downloaded (Parakeet 2.5 GB ≈ 7.5 h; `gemma4:e4b` 9.6 GB ≈ 23 h).
Substitutions actually in use:

| Role | Planned | **Actually used** | Why |
|---|---|---|---|
| ASR | `parakeet-tdt-0.6b-v3` | **`mlx-community/whisper-base-mlx`** (144 MB) | only viable download |
| Rerank LLM | `gemma4:e4b` | **`llama3.1:8b` via Ollama** | already on disk, 0 bytes to fetch |

**Track B:** byLLM must point at `ollama/llama3.1:8b`, *not* `ollama/gemma-4-e4b`.

Parakeet remains the preferred ASR and is fully implemented in `pipeline/asr.py`.
It auto-activates the moment its weights appear in the HF cache — no code change.
Force a backend with `IDIOLECT_ASR_BACKEND=whisper|parakeet`.

Everything runs locally. Nothing goes to a hosted API.

## Ollama

Must be running. Always pass `keep_alive: -1` on requests (the pipeline does) so
the model never unloads and cold-starts in front of judges.

## Timing

All hacking must occur between 10:45 AM and 7:15 PM today; commit timestamps
are checked.
