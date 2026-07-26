# Build plan — 2 people, parallel tracks

Working name: **Idiolect**. Stack is locked; this doc is execution only.

**Read this first if you are Claude Code:** see [Notes for Claude Code](#notes-for-claude-code) at the bottom before writing any Jac.

---

## The contract (agree on this before anyone writes code)

Everything else in this plan depends on two function signatures. Both people code against these from minute one.

```python
# Track A owns the real implementations
def transcribe(audio_path: str) -> list[str]:
    """Return n-best candidate transcriptions, best first."""

def rerank(candidates: list[str], vocab: list[str], context: list[str]) -> str:
    """Pick or rewrite the best candidate given personal vocabulary
    and the last few utterances. Returns final text."""
```

**Track B stubs both immediately** and builds the entire app against fakes:

```python
def transcribe(audio_path): return ["the cat sat", "the cat set", "the hat sat"]
def rerank(candidates, vocab, context): return candidates[0]
```

Track A swaps the real ones in at the sync point. **Neither person is ever blocked on the other.** If you change these signatures, tell the other person out loud.

---

## Setup — both people, first 20 minutes

Do this together, once.

```bash
git init                      # AFTER 10:45 AM — organizers check commit timestamps
brew install ffmpeg
pip install jaclang jaseci byllm jac-client parakeet-mlx
```

Repo layout:

```
idiolect/
├── CLAUDE.md              # project context for Claude Code
├── llmdocs-jaseci.txt     # Jac syntax reference — see notes at bottom
├── jac.toml
├── main.jac               # entry point
├── models.jac             # nodes + edges          [Track B]
├── walkers.jac            # walkers                [Track B]
├── components/
│   └── Recorder.cl.jac    # mic capture + UI       [Track B]
├── pipeline/
│   ├── asr.py             # transcribe()           [Track A]
│   ├── rerank.py          # rerank()               [Track A]
│   └── stubs.py           # fakes, delete at sync  [Track B writes]
└── eval/
    ├── torgo.py           # data prep + WER        [Track A]
    └── curve.json         # cached output          [Track A]
```

Then split. Do not pair-program; you don't have the hours.

---

## Track A — Pipeline & Evidence

You own everything from audio bytes to final text, plus the accuracy curve.

### A1. Parakeet running (target: 30 min)

```bash
parakeet-mlx test.wav --output-format json
```

Record any short wav yourself to test. Model is ~2.5 GB on first pull.

**Done when:** you get correct text back from a file you recorded.

### A2. N-best extraction (target: 45 min)

Use the Python API, not the CLI. Enable beam decoding and pull multiple hypotheses — the beam flags (`length_penalty`, `patience`, `duration_reward`) only apply in beam mode, so greedy will give you exactly one candidate and nothing to rerank.

**Done when:** `transcribe()` returns 3–5 genuinely different candidates for one utterance.

**If beam N-best proves hard to extract:** fall back to running the same audio at 2–3 different decoding settings and dedupe. Ugly, works, move on. Do not spend more than 45 minutes here.

### A3. Ollama + Gemma 4 (target: 20 min)

```bash
ollama pull gemma-4-e4b
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

**`OLLAMA_KEEP_ALIVE=-1` is not optional.** Without it the model unloads and you eat a 20-second cold start in front of judges.

**Done when:** a curl to the local endpoint returns a completion in under 2 seconds.

### A4. The rerank prompt (target: 60 min)

This is the intellectual core of the project. Give Gemma the candidate list, the personal vocabulary, and the last 3 utterances. Ask it to pick one or repair one.

Prompt requirements:
- Output the corrected text only — no preamble, no explanation
- Must be allowed to output a candidate verbatim if it's already right
- Must be allowed to repair a single word rather than swap the whole utterance

**Done when:** feeding it a deliberately mangled candidate plus a vocabulary containing the right word produces the right word.

### A5. TORGO (target: 60 min)

Source: `cs.toronto.edu/~complingweb/data/TORGO/torgo.html`. Academic use only — cite it in the README.

**Do not download all 18 GB.** Pull one ALS speaker directory only.

1. Filter to **sentence-level utterances**. Drop isolated words — they starve the context layer and are the hardest category even for challenge-winning systems.
2. Split **by prompt text**, not randomly. A test prompt must never appear in the correction stream. TORGO repeats prompts across sessions; a random split leaks vocabulary and inflates your numbers.
3. ~70 utterances in the correction stream, ~25 held out.

### A6. The accuracy curve (target: 60 min)

Simulate the correction loop offline: feed the correction stream in order, growing the vocabulary as you go, and evaluate WER on the held-out set after every 10 corrections.

Report **two** curves:
- **Shared vocabulary** — test prompts share words with the correction stream. Realistic; people repeat their own words. Bigger gains.
- **Unshared vocabulary** — no overlap. The hard case. Smaller gains. Show it anyway.

Baseline line on the same chart: **Whisper large-v3, unpersonalized.** Beat the actual state of the art, not a strawman.

**Write results to `eval/curve.json` and cache it.** Never compute this live during the demo.

### A7. Gemma native audio (only if A1–A6 are done)

Add Gemma's audio path as a second hypothesis source — but **only invoke it when Parakeet's candidates disagree with each other.** Selective escalation. Halves your inference cost and is a better architecture than running both every time.

---

## Track B — App & Jac

You own the graph, the walkers, and everything the judges look at.

### B1. Stubs + scaffold (target: 30 min)

Write `pipeline/stubs.py` with the two fake functions above. Then:

```bash
jac create --use client
jac start --client web --dev
```

**Done when:** a page renders in the browser with hot reload working.

### B2. Mic capture (target: 45 min — do this before anything else)

**Highest-variance task in the whole project.** Everything downstream needs it.

In `components/Recorder.cl.jac`: `navigator.mediaDevices.getUserMedia()` → `MediaRecorder` → POST the blob to a walker.

Two things that will bite you:
- `getUserMedia` requires a secure context. `localhost` is fine. **Another device on the venue wifi is not.** Demo from this laptop — decide that now.
- Grant the mic permission in the browser once and don't switch browsers later.

**Done when:** you record 3 seconds, POST it, and a walker receives a file it can write to disk.

**If jac-client fights you on Web APIs past 45 minutes:** write a ~30-line vanilla JS recorder in a plain `<script>`, POST to the Jac backend, keep everything else in Jac. Your Jac percentage stays well past 40%.

### B3. Graph schema (target: 30 min)

In `models.jac`:

| Node | Fields |
|---|---|
| `Session` | started_at |
| `Utterance` | audio_path, timestamp, final_text |
| `Candidate` | text, rank, source (parakeet / gemma) |
| `Correction` | chosen_text, method (picked / edited / typed) |
| `VocabEntry` | term, count, first_seen |

Edges: `Session -> Utterance -> Candidate`, `Utterance -> Correction`, `Session -> VocabEntry`.

### B4. Walkers (target: 90 min)

This is where your Jac percentage comes from. Write real logic here, not thin wrappers.

- `Transcribe` — takes audio, calls `transcribe()`, spawns `Candidate` nodes
- `Rerank` — gathers `VocabEntry` terms and the last 3 utterances, calls `rerank()`, sets a preferred candidate. Use `by llm()` for the reranking function so byLLM handles prompt construction and type-validated output.
- `AcceptCorrection` — writes a `Correction`, extracts new terms into `VocabEntry`, bumps counts
- `BuildTrainingSet` — traverses all corrections, emits JSONL

Point byLLM at Ollama: `default_model = "ollama/gemma-4-e4b"`.

### B5. Correction UI (target: 60 min)

- Candidate list, tap to accept
- Word-level correction — tap one word to fix it rather than retyping the sentence
- Type-it-yourself fallback, last resort
- Personal vocabulary panel, visibly growing as corrections land

**The growing vocabulary panel is the demo.** Judges need to *see* the system learning. Make it obvious.

### B6. Metrics display (target: 30 min)

Load `eval/curve.json` from Track A and render both curves plus the Whisper baseline. Live session WER counter next to it.

---

## Sync points

| Time | What |
|---|---|
| **~1:00 PM** | Track A hands over real `transcribe()`. Track B deletes `stubs.py`'s transcribe fake. |
| **~3:30 PM** | Track A hands over real `rerank()`. Full loop runs end to end. |
| **~4:00 PM** | **Go/no-go on LoRA.** If the loop isn't working end to end, LoRA is off. No debate. |
| **5:50 PM** | **Partial submission on Devpost. Mandatory. Both stop and do it.** |
| **~6:30 PM** | Record the demo video. Do this before you're tired and before anything else breaks. |
| **7:15 PM** | Submissions close. Hard. |

---

## Definition of done

The demo works if all five are true:

1. Speak into the mic, see candidates
2. Correct one, see it stored
3. Vocabulary panel visibly grows
4. A later utterance using that vocabulary is transcribed correctly
5. The TORGO curve renders

Anything beyond this is optional. If you are behind at 4:00 PM, cut in this order: LoRA → Gemma native audio → word-level correction → the unshared-vocabulary curve.

---

## Submission checklist

- [ ] GitHub link, ≥40% Jac
- [ ] Demo video
- [ ] Written description including how Jac was used
- [ ] Star `github.com/jaseci-labs/jac`
- [ ] Tracks selected: **Social Impact**, **Best Use of Jaclang**
- [ ] README cites TORGO (Rudzicz et al. 2012) and attributes Parakeet (CC-BY-4.0)
- [ ] Proxy-speaker disclosure stated in the writeup, not just verbally

---

## Notes for Claude Code

**Jac is barely present in training data. Claude Code will confidently invent syntax that doesn't compile.** Mitigate before you start:

1. Download the Jac LLM syntax reference from `docs.jaseci.org/learn/tools/llmdocs/` into the repo as `llmdocs-jaseci.txt`.
2. In `CLAUDE.md`, write: *"This project is written in Jac. Always consult `llmdocs-jaseci.txt` for syntax before writing or editing any `.jac` file. Do not infer Jac syntax from Python or JavaScript."*
3. Compile early and often — `jac run main.jac`. Do not let 200 lines of unverified Jac accumulate.

Other context worth putting in `CLAUDE.md`:

- Mac, Apple Silicon. MLX and Metal, never CUDA.
- Parakeet runs through `parakeet-mlx`, not NeMo.
- Gemma runs through Ollama locally. Nothing goes to a hosted API.
- Frontend components are `.cl.jac` files, JSX syntax, Vite under the hood.
- All hacking must occur between 10:45 AM and 7:15 PM today; commit timestamps are checked.
