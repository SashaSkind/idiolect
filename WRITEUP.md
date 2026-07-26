# Kaggle writeup — copy/paste into the form

## TITLE (80 char limit)

```
Idiolect: on-device speech recognition that learns your own words
```

## SUBTITLE (140 char limit)

```
Dysarthric speech correction that learns your personal words from your own corrections. Gemma 4 E4B, fully on-device, 69% fewer errors.
```

---

## PROJECT DESCRIPTION

### 💡 Inspiration

Speech recognition fails the people who need it most. For someone with
dysarthria — the speech disability caused by cerebral palsy, ALS, Parkinson's
or stroke — general ASR error rates run several times higher than for typical
speech. The cruel part is that the *same* physical conditions often make a
keyboard or touchscreen difficult too, so voice is not a convenience, it is
the interface.

And the words that fail are the words that matter. A general model has never
heard your carer's name, your street, or the drug you take twice a day. We
watched a recogniser turn **"baclofen"** into **"battle fender"**, **"back
fluff end"**, and **"battle of n"**. Your medication becomes noise.

The usual fix is to fine-tune per speaker, which needs hours of labelled audio
that a disabled user has to record while their voice tires. We wanted the
opposite: a system that **learns from the corrections you were going to make
anyway**. You fix a word once; it remembers. Zero training, zero recording
sessions, and nothing leaves the device.

### ⚙️ How we built it

**Gemma 4 E4B via Ollama, fully local.** No hosted API, no network at demo
time. That is a requirement rather than a preference: the vocabulary this
system learns is medical and personal, and "where does my voice go?" deserves
a clean answer.

The pipeline is deliberately two-stage, using each model for what it is good
at:

1. **Parakeet TDT 0.6B (MLX)** produces an *n-best list* of candidate
   transcriptions — not one guess, several. It is the stronger pure
   transcriber.
2. **Gemma 4 E4B** picks or repairs the best candidate, given the speaker's
   personal vocabulary and their last three utterances. This is the step that
   needs language understanding rather than acoustics.

**Prompt engineering, not fine-tuning.** Nothing is trained. Personalisation
is entirely a growing vocabulary harvested from the user's own corrections and
fed to Gemma as context — closer to contextual biasing / RAG-over-your-own-
vocabulary than to adaptation.

**Getting an n-best list at all** was the first real problem. Both Parakeet
and Whisper compute a full ranked list of hypotheses during beam search and
then throw away everything except the winner. Rather than reimplement beam
search, we take the *installed source* of the deciding method, swap the single
call that collapses the list, and rebind it — so the top-1 result is
bit-identical to the library's, but the discarded alternatives survive for
Gemma to choose between. Deriving the patch from installed source means it
cannot silently drift out of sync with the library.

**Orchestrated in Jac/Jaseci.** The graph *is* the memory: nodes for sessions,
utterances, candidates, corrections and vocabulary entries; walkers for
transcription, reranking, accepting a correction and building a training
corpus. Accepting a correction spawns `VocabEntry` nodes, which the next
rerank walks. The vocabulary panel the user watches grow is just a view of the
graph.

**Stack:** Jac/Jaseci · Gemma 4 E4B via Ollama · Parakeet TDT 0.6B via MLX ·
Apple Silicon, Metal, no CUDA · Python pipeline behind a two-function contract.

### 📊 Results

Measured on a personal-vocabulary benchmark (four synthesised proxy voices —
**not** dysarthric speech, and we say so), degraded to baseline WER 0.258,
chosen to sit near real data: TORGO's F03 speaker measures 0.196 with the same
recogniser.

| | baseline | after 14 corrections | |
|---|---|---|---|
| Error on **personal terms** (R-WER) | 0.593 | **0.185** | **−69%** |
| Overall WER | 0.258 | **0.121** | **−53%** |

R-WER — error restricted to the speaker's own terms — is the metric that
matters here, and is standard for contextual biasing. Overall WER dilutes a
dozen rare words among a hundred common ones the recogniser already gets
right.

**On real dysarthric speech (TORGO, speaker F03) we measure no gain: 0.196
before, 0.196 after 100 corrections.** We are reporting that rather than
hiding it, because the reason is interesting. TORGO's prompts are
phonetically-balanced TIMIT sentences ("she had your dark suit in greasy wash
water"), so the vocabulary a correction stream harvests is ordinary English
the recogniser already handles. We measured the opportunity rate directly: a
previously-corrected word is mis-recognised in only **3 of 25** held-out
utterances, capping any achievable gain below one WER point — under the noise
floor. A flat TORGO curve is the *expected* result there, and what it does
establish is a safety property worth having: **the system never corrupts a
transcription it cannot improve.**

We also swept how badly the audio is degraded, because "why not test on worse
audio?" is the obvious question:

| baseline WER | R-WER before → after | gain |
|---|---|---|
| 0.19 | 0.519 → 0.074 | **+86%** |
| 0.31 | 0.741 → 0.370 | +50% |
| 0.41 | 0.741 → 0.593 | +20% |
| 0.67 | 0.852 → 0.852 | **0%** |

Gain *falls* as audio worsens. Personal vocabulary can only repair an error
that still carries evidence of the word: `baclofen → "battle fan"` is
recoverable, `Gaviscon → "tablets"` is not, because the recogniser has
confidently substituted an unrelated real word and the information is gone.
This feature helps most where a recogniser is mostly right but mishears the
names that matter.

### 🚀 The Prototype

- **Demo video:** [INSERT 2-MINUTE DEMO VIDEO LINK]
- **GitHub repo:** https://github.com/SashaSkind/idiolect

Speak → see candidates → correct one → watch the vocabulary panel grow → say
something new using that word → it comes back right.

### 🧩 Challenges we ran into

**The reranker hallucinated fluent nonsense.** Handing Gemma the speaker's
whole vocabulary was actively harmful. Given forty unrelated words it
assembled them into a plausible sentence with no relation to the audio: the
candidate *"he slowly kicks a slight walk in the open area"* came back as
*"He skillfully plays upon each organ, except for a small walk in the snow"* —
every injected word lifted from the vocabulary list. Accuracy got **worse** as
the system learned more (0.152 → 0.230). The fix was to constrain rather than
to prompt harder: vocabulary is matched against joined candidate spans (a word
is often misheard as several — "back fluff end"), consensus words must
survive, and no word may appear that isn't in the candidates or the offered
terms.

**A one-line config bug that looked like a model being bad.** Gemma 4 is a
reasoning model: it routes its answer into a separate `thinking` field, and
our `"\n\n"` stop sequence made it return an empty string on *every* call. The
system silently fell back to the top candidate and personalisation appeared to
do nothing. We nearly wrote it up as "Gemma underperforms here". It was our
client code. With `think: false`, Gemma 4 answers correctly and, warm, runs at
0.59s — and gives a *better*, monotone curve than the alternative we tested.

**Matching a known spelling is a string problem, not a language-model
problem.** Every remaining miss had the right term already in front of the
model, which simply declined to use it — "gaviscan" left standing next to
Gaviscon. We added a deterministic pass that snaps unrecognised tokens onto
personal terms, but only ones the dictionary doesn't know — names, places,
drugs. Restricted that way it fixes the rare words; unrestricted it damaged
TORGO by rewriting ordinary English.

**The venue wifi collapsed to 90 KB/s** an hour in, with a 23-hour ETA on the
Gemma download. We built the entire pipeline against a 144 MB fallback model
behind a stable two-function contract, then hot-swapped the real models in
when the network recovered — no code changes, because the contract held.

### 🔭 What's next

Gemma 4's native audio path as a *second* hypothesis source, invoked only when
Parakeet's candidates disagree — selective escalation rather than running both
every time. And the honest next step for the evaluation: real dysarthric
speakers saying their own words, which is the one thing no public corpus
currently provides.

### Attribution

TORGO database: Rudzicz, F., Namasivayam, A. K., & Wolff, T. (2012). *The
TORGO database of acoustic and articulatory speech from speakers with
dysarthria.* Language Resources and Evaluation, 46(4). Academic use only.
Parakeet TDT (NVIDIA, CC-BY-4.0). Gemma 4 (Google). Proxy-speaker disclosure:
the benchmark and demo use synthesised/non-dysarthric proxy speech; no
dysarthric speaker recorded audio for this project.
