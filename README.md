# Idiolect

Idiolect is a local dictation app that learns a speaker's personal vocabulary
from ordinary transcript corrections. It is the Track B (App & Jac) build for
JacHacks SF 2026.

## What works

- Browser microphone capture with `MediaRecorder`
- Typed Jac walkers for transcription, reranking, correction, and export
- Persistent Jac graph for sessions, utterances, candidates, corrections, and
  vocabulary
- Immediate vocabulary-biased reranking
- Visible baseline-versus-personalized transcript comparison
- Cached evaluation chart, ready for Track A's TORGO results
- Local JSONL training-set export

## Run locally

Install Jac using the current
[official instructions](https://docs.jaseci.org/getting-started/installation/),
then run:

```bash
jac install
jac start --dev main.jac
```

Open <http://localhost:8000>. Grant microphone permission in that browser and
keep the demo on localhost, since browser microphone access requires a secure
context.

The app explicitly disables Jac's `sv import` microservice auto-extraction in
`jac.toml`. For this laptop-only MVP, the UI and walkers intentionally run as
one process.

## Track A handoff

The app preserves these contracts:

```python
def transcribe(audio_path: str) -> list[str]: ...
def rerank(candidates: list[str], vocab: list[str], context: list[str]) -> str: ...
```

Replace the fallback implementations by adding `pipeline/real_asr.py` and
`pipeline/real_rerank.py`. No Jac or client code needs to change.

Track A should also replace `eval/curve.json`; the checked-in values are
explicitly labeled placeholder data in the UI.

## Evaluation data

The intended evaluation corpus is the [TORGO database of dysarthric
speech](https://www.cs.toronto.edu/~complingweb/data/TORGO/torgo.html), free
for academic/non-profit use. Cite:

Rudzicz, F., Namasivayam, A. K., & Wolff, T. (2012). *The TORGO database of
acoustic and articulatory speech from speakers with dysarthria*. Language
Resources and Evaluation, 46(4), 523–541.
