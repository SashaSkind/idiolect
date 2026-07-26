# Kaggle writeup — copy/paste

## TITLE (80 limit)

```
Idiolect: on-device speech recognition that learns your own words
```

## SUBTITLE (140 limit)

```
Dysarthric speech correction that learns your personal words from your own corrections. Gemma 4 E4B, fully on-device, 69% fewer errors.
```

## PROJECT DESCRIPTION — paste everything below this line

### 💡 Inspiration

Speech recognition fails the people who need it most. For someone with dysarthria — the speech disability caused by cerebral palsy, ALS, Parkinson's or stroke — error rates run several times higher than for typical speech. The cruel part is that the same conditions often make a keyboard or touchscreen hard too, so voice isn't a convenience, it's the interface.

And the words that fail are the words that matter most. A general model has never heard your carer's name, your street, or the drug you take twice a day. We watched a recogniser turn **"baclofen"** into *"battle fender"*, *"back fluff end"*, and *"battle of n"*. Your medication becomes noise.

The usual fix is per-speaker fine-tuning, which needs hours of labelled audio that a disabled user must record while their voice tires. We wanted the opposite: a system that **learns from the corrections you were going to make anyway**. Fix a word once; it remembers. Zero training, no recording sessions, nothing leaves the device.

### ⚙️ How we built it

**Gemma 4 E4B via Ollama, fully local.** No hosted API, no network at demo time — a requirement, not a preference: the vocabulary this system learns is medical and personal, and *"where does my voice go?"* deserves a clean answer.

Two stages, each model doing what it's good at:

1. **Parakeet TDT 0.6B (MLX)** produces an *n-best list* of candidate transcriptions — not one guess, several.
2. **Gemma 4 E4B** picks or repairs the best candidate given the speaker's personal vocabulary and their last three utterances — the step that needs language understanding rather than acoustics.

**Prompt engineering, not fine-tuning.** Nothing is trained. Personalisation is entirely a growing vocabulary harvested from the user's own corrections and supplied to Gemma as context — closer to contextual biasing (RAG over your own vocabulary) than to model adaptation.

**Getting an n-best list at all** was the first real problem. Parakeet and Whisper both compute a full ranked list of hypotheses during beam search, then discard everything except the winner. Rather than reimplement beam search, we take the *installed source* of the deciding method, swap the single call that collapses the list, and rebind it — top-1 stays bit-identical to the library's, but the discarded alternatives survive for Gemma to choose between.

**Orchestrated in Jac/Jaseci, where the graph is the memory.** Nodes for sessions, utterances, candidates, corrections and vocabulary; walkers for transcribing, reranking, accepting a correction, and building a corpus. Accepting a correction spawns `VocabEntry` nodes that the next rerank walks. The vocabulary panel users watch grow is just a view of the graph.

**Stack:** Jac/Jaseci · Gemma 4 E4B (Ollama) · Parakeet TDT 0.6B (MLX) · Apple Silicon/Metal, no CUDA.

**What we measured.** On a personal-vocabulary benchmark (four synthesised proxy voices — **not** dysarthric speech, and we say so), degraded to baseline WER 0.258, chosen to sit near real data: TORGO's F03 speaker measures 0.196 with the same recogniser.

| | baseline | after 14 corrections | |
|---|---|---|---|
| Error on **personal terms** (R-WER) | 0.593 | **0.185** | **−69%** |
| Overall WER | 0.258 | **0.129** | **−50%** |

On real dysarthric speech (TORGO) we measure **no gain: 0.196 baseline against 0.206 after 100 corrections**, a difference inside the run-to-run noise (checkpoints span 0.191–0.211) — and we report it, because the reason is interesting. TORGO's prompts are phonetically-balanced TIMIT sentences, so the vocabulary harvested is ordinary English the recogniser already handles. A previously-corrected word is mis-recognised in only **3 of 25** held-out utterances, capping any possible gain below one WER point — under the noise floor. What TORGO *does* establish is that personalisation **neither helps nor meaningfully harms** where it has nothing to offer — which matters, because an earlier version of our reranker degraded accuracy badly as it learned (0.152 → 0.230).

We also swept degradation, since *"why not test on worse audio?"* is the obvious question. Gain **falls** as audio worsens (+86% at WER 0.19 → 0% at 0.67). Personal vocabulary can only repair an error that still carries evidence of the word: `baclofen → "battle fan"` is recoverable; `Gaviscon → "tablets"` is not, because the recogniser confidently substituted an unrelated real word and the information is gone.

### 🚀 The Prototype

[INSERT LINK TO YOUR 2-MINUTE DEMO VIDEO HERE]

https://github.com/SashaSkind/idiolect

Speak → see candidates → correct one → watch the vocabulary panel grow → say something new using that word → it comes back right.

### 🧩 Challenges we ran into

**The reranker hallucinated fluent nonsense.** Handing Gemma the whole vocabulary was actively harmful. Given forty unrelated words it assembled them into a plausible sentence unrelated to the audio: the candidate *"he slowly kicks a slight walk in the open area"* came back as *"He skillfully plays upon each organ, except for a small walk in the snow"* — every injected word lifted from the vocabulary list. Accuracy got **worse** as the system learned more (0.152 → 0.230). The fix was to constrain rather than prompt harder: vocabulary is matched against *joined* candidate spans (a word is often misheard as several — "back fluff end"), consensus words must survive, and no word may appear that isn't in the candidates or the offered terms.

**A one-line config bug that looked like a model being bad.** Gemma 4 is a reasoning model — it routes its answer into a separate `thinking` field, and our `"\n\n"` stop sequence made it return an empty string on *every* call. The system silently fell back to the top candidate and personalisation appeared to do nothing. We nearly wrote it up as "Gemma underperforms here." It was our client code. With `think: false` Gemma 4 answers correctly, runs at 0.59s warm, and gives a *better*, monotone curve than the alternative we tested.

**Matching a known spelling is a string problem, not a language-model problem.** Every remaining miss already had the right term in front of the model, which simply declined to use it — "gaviscan" left standing next to Gaviscon. We added a deterministic pass that snaps unrecognised tokens onto personal terms, but only ones the dictionary doesn't know: names, places, drugs. Restricted that way it fixes rare words; unrestricted it damaged TORGO by rewriting ordinary English.

**The venue wifi collapsed to 90 KB/s** an hour in, with a 23-hour ETA on the Gemma download. We built the whole pipeline against a 144 MB fallback model behind a stable two-function contract, then hot-swapped the real models in when the network recovered — no code changes, because the contract held.

**What's next:** Gemma 4's native audio path as a *second* hypothesis source, invoked only when Parakeet's candidates disagree — selective escalation rather than running both every time.

*Attribution: TORGO (Rudzicz et al., 2012), academic use only. Parakeet TDT (NVIDIA, CC-BY-4.0). Gemma 4 (Google). Proxy-speaker disclosure: the benchmark and demo use synthesised/non-dysarthric proxy speech; no dysarthric speaker recorded audio for this project.*
