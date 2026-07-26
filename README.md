# Idiolect

**On-device speech recognition that learns your own words.**

Speech recognition fails the people who need it most. For someone with
dysarthria — the speech disability caused by cerebral palsy, ALS, Parkinson's
or stroke — error rates run several times higher than for typical speech, and
the same conditions often make a keyboard or touchscreen difficult too. Voice
isn't a convenience; it's the interface.

And the words that fail are the words that matter. A general model has never
heard your carer's name, your street, or the drug you take twice a day:

```
you said       "I need my baclofen before physio"
Parakeet hears "I need my battle fender for phys"
Idiolect says  "I need my baclofen for physio"      ← because you corrected it once
```

The usual fix is per-speaker fine-tuning, which demands hours of labelled audio
recorded by someone whose voice tires. Idiolect does the opposite: it learns
from **the corrections you were going to make anyway**. Fix a word once, it
remembers. Zero training, and nothing leaves the machine.

**▶ [Watch the 2-minute demo](https://youtu.be/gN7w_Fb1kpw)**

Built for JacHacks SF 2026 / the Gemma 4 Challenge.

---

## Gemma 4 is the correction engine

Idiolect runs **Gemma 4 E4B locally through Ollama**. It is the component that
makes the system personal.

The acoustic model is fixed and speaker-independent — it will never know who
you are. Everything Idiolect learns about *you* arrives at the Gemma 4 step, as
a vocabulary harvested from your past corrections plus your last few
utterances. Gemma sees the recogniser's competing guesses and decides which one
you meant, repairing a word where the evidence supports it.

```
  audio ──▶ Parakeet TDT 0.6B ──▶ n-best candidates ──┐
                (MLX, acoustics)                       │
                                                       ▼
                     your vocabulary ──────▶  Gemma 4 E4B  ──▶ final text
                     last 3 utterances ─────▶  (Ollama)
                                                       │
                     you correct a word ◀──────────────┘
                             │
                             └──▶ new VocabEntry in the Jac graph
```

**Prompt engineering, not fine-tuning.** Nothing is trained. Personalisation is
context — closer to contextual biasing (RAG over your own vocabulary) than to
model adaptation. That is what makes it work from *one* correction instead of
hours of audio.

**Why a second model at all?** Gemma 4 is not a state-of-the-art ASR model and
we don't pretend otherwise. Parakeet is the better pure transcriber; Gemma 4 is
better when the task needs language understanding — which candidate is a
sentence a person would actually say, and which mangled span is really
*baclofen*. Each model does what it is good at.

**Two things worth knowing if you use Gemma 4 this way:**

- It is a **reasoning model**. It routes its answer into a separate `thinking`
  field, so you must pass `think: false` — otherwise it spends the token budget
  reasoning and returns empty content. This cost us an afternoon and looked
  exactly like "the model is bad at this task."
- Warm, it answers in **~0.6 s**, and on our benchmark it beat the alternative
  we tested (llama3.1:8b) with a cleanly monotone accuracy curve.

Everything is local. No hosted API, no network at demo time. That's a
requirement rather than a preference: the vocabulary this system learns is
medical and personal, and *"where does my voice go?"* deserves a clean answer.

---

## Results

On a personal-vocabulary benchmark — four synthesised proxy voices, **not**
dysarthric speech (see [disclosure](#honest-limitations)) — degraded to
baseline WER 0.258, chosen to sit near real data: TORGO's F03 speaker measures
0.196 with the same recogniser.

| | baseline | after 14 corrections | |
|---|---|---|---|
| Error on **personal terms** (R-WER) | 0.593 | **0.185** | **−69%** |
| Overall WER | 0.258 | **0.129** | **−50%** |

R-WER — error restricted to the speaker's own terms — is the metric that
matters here and is standard for contextual biasing. Overall WER dilutes a
dozen rare words among a hundred common ones the recogniser already gets right.

**On real dysarthric speech (TORGO) we measure no gain:** 0.196 baseline
against 0.206 after 100 corrections, inside run-to-run noise. We report it
because the reason is informative. TORGO's prompts are phonetically-balanced
TIMIT sentences, so the vocabulary a correction stream harvests is ordinary
English the recogniser already handles — a previously-corrected word is
mis-recognised in only **3 of 25** held-out utterances, capping any possible
gain below one WER point. What TORGO does establish is that personalisation
neither helps nor meaningfully harms where it has nothing to offer, which
matters: an earlier version of our reranker degraded accuracy badly as it
learned (0.152 → 0.230).

**Harder audio does not mean more to gain.** We swept it:

| baseline WER | R-WER before → after | gain |
|---|---|---|
| 0.19 | 0.519 → 0.074 | **+86%** |
| 0.31 | 0.741 → 0.370 | +50% |
| 0.41 | 0.741 → 0.593 | +20% |
| 0.67 | 0.852 → 0.852 | **0%** |

Personal vocabulary can only repair an error that still carries evidence of the
word. `baclofen → "battle fan"` is recoverable; `Gaviscon → "tablets"` is not,
because the recogniser has confidently substituted an unrelated real word and
the information is gone. This helps most where a recogniser is mostly right but
mishears the names that matter.

Full analysis: [`eval/FINDINGS.md`](eval/FINDINGS.md).

---

## Quickstart

**Prerequisites** — macOS on Apple Silicon (MLX/Metal, never CUDA):

```bash
brew install ffmpeg
ollama pull gemma4:e4b          # 9.6 GB, the correction engine
ollama serve                    # keep running
pip install parakeet-mlx        # Parakeet weights (~2.5 GB) pull on first use
```

Install Jac using the current
[official instructions](https://docs.jaseci.org/getting-started/installation/),
then:

```bash
jac install
jac start --dev main.jac
```

Open <http://localhost:8000>, grant microphone permission, and keep the demo on
localhost — browser microphone access requires a secure context, so another
device on the same wifi will not work.

The app disables Jac's `sv import` microservice auto-extraction in `jac.toml`:
for this laptop-only build, UI and walkers run as one process.

### Try the pipeline without the UI

```bash
python3 pipeline/asr.py audio/hard.wav   # n-best candidates
python3 pipeline/rerank.py               # correction cases, with and without vocabulary
```

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `IDIOLECT_RERANK_MODEL` | `gemma4:e4b` | any Ollama model |
| `IDIOLECT_ASR_BACKEND` | auto | `parakeet` or `whisper` |
| `IDIOLECT_WHISPER_MODEL` | `whisper-small-mlx` | fallback ASR |
| `OLLAMA_URL` | `http://localhost:11434` | Ollama endpoint |

Parakeet is selected automatically when its weights are present; Whisper is a
complete fallback backend behind the same contract.

---

## How it's built

The graph **is** the memory. Nodes for sessions, utterances, candidates,
corrections and vocabulary; walkers for transcribing, reranking, accepting a
correction and exporting a corpus. Accepting a correction spawns `VocabEntry`
nodes that the next rerank walks — the vocabulary panel users watch grow is
just a view of the graph.

```
main.jac  models.jac  walkers.sv.jac   Jac app: graph, walkers, API
frontend.cl.jac  components/*.cl.jac   Jac client UI
pipeline/asr.py                        transcribe(audio_path) -> list[str]
pipeline/rerank.py                     rerank(candidates, vocab, context) -> str
eval/                                  benchmarks, WER, cached curves
```

The pipeline sits behind two functions, which is why the models could be
swapped mid-build without touching the app:

```python
def transcribe(audio_path: str) -> list[str]: ...          # n-best, best first
def rerank(candidates, vocab, context) -> str: ...         # final text
```

**Getting an n-best list at all** was the first real problem. Parakeet and
Whisper both compute a full ranked list of hypotheses during beam search, then
discard everything but the winner. Rather than reimplement beam search,
`pipeline/asr.py` takes the *installed source* of the deciding method, swaps the
single call that collapses the list, and rebinds it — top-1 stays bit-identical
to the library's, but the alternatives survive for Gemma to choose between.
Because the patch is derived from installed source at import time it cannot
silently drift out of sync with the library.

### Reproducing the evaluation

```bash
python3 eval/proxy.py        # personal-vocabulary benchmark -> proxy_curve.json
python3 eval/difficulty.py   # gain vs input difficulty     -> difficulty.json
python3 eval/curve.py        # TORGO simulation             -> torgo_curve.json
python3 eval/display.py      # chart data the app loads     -> curve.json
```

TORGO audio is not redistributed here; download it separately into
`data/torgo/` (see below). The other benchmarks generate their own audio.

---

## Honest limitations

- **The proxy benchmark is synthesised speech, not dysarthric speech.** No
  person with dysarthria recorded audio for this project. It isolates the
  mechanism — can a mis-heard personal word be recovered — and is *not* an
  estimate of real-world gain.
- Its sentences were written to contain personal vocabulary, so the opportunity
  rate is high by construction.
- Degradation is acoustic (level, tempo, muffling, noise), not articulatory.
  Dysarthria is not a low-pass filter.
- On real dysarthric speech we show no measurable gain, for the reason analysed
  above.
- The honest next step is real dysarthric speakers saying **their own words** —
  which is precisely what no public corpus currently provides.

---

## Attribution

**TORGO database** — free for academic/non-profit use:

> Rudzicz, F., Namasivayam, A. K., & Wolff, T. (2012). *The TORGO database of
> acoustic and articulatory speech from speakers with dysarthria.* Language
> Resources and Evaluation, 46(4), 523–541.

**Parakeet TDT 0.6B** — NVIDIA, CC-BY-4.0, via
[`parakeet-mlx`](https://github.com/senstella/parakeet-mlx).
**Gemma 4 E4B** — Google, via [Ollama](https://ollama.com).
Built with [Jac / Jaseci](https://github.com/jaseci-labs/jac).
