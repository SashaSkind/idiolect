# Idiolect — submission bundle

**Demo video:** https://youtu.be/gN7w_Fb1kpw
**Repository:** https://github.com/SashaSkind/idiolect

Start with **README.md**. Measured results and their limitations are in
**eval/FINDINGS.md**; the writeup text is **WRITEUP.md**.

## Run it

```bash
.venv/bin/jac start --dev main.jac      # then open http://localhost:8000
```

Needs Ollama running with `gemma4:e4b`, plus `parakeet-mlx` on Apple Silicon.

## What's here

```
*.jac  components/  styles/     the Jac application (graph, walkers, UI)
pipeline/asr.py                 n-best transcription (Parakeet + Gemma 4 audio)
pipeline/rerank.py              personalised reranking (Gemma 4 E4B)
eval/                           benchmarks, WER, cached results
data/proxy/  data/difficulty/   synthesised benchmark audio, 140 clips
```

## Hear it

```bash
python3 eval/listen.py && open listen.html
afplay data/difficulty/mild_000.wav     # "has Nadia collected my baclofen yet"
afplay data/difficulty/severe_000.wav   # same sentence, past the threshold
```

## What is deliberately NOT here

**TORGO audio.** Licensed for academic/non-profit use, not redistributable.
Every TORGO number we report comes from it; we ship none of it. Download it
into `data/torgo/`, then:

```bash
python3 eval/make_samples.py    # demo clips for the UI button
python3 eval/curve.py           # reproduce the TORGO evaluation
```

Audio that *is* included (`data/proxy`, `data/difficulty`) is **synthesised
proxy speech we generated** — not dysarthric speech, labelled as such
throughout.

## Reproduce the numbers

```bash
python3 eval/proxy.py        # personal-vocabulary benchmark: R-WER -87%
python3 eval/difficulty.py   # gain vs input difficulty
python3 eval/display.py      # chart data the app loads
```
