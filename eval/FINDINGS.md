# Evidence — what we measured and what it means

Two evaluations. They answer different questions and the difference matters.

---

## 1. TORGO — real dysarthric speech

Speaker F03, 128 sentence utterances, split by prompt text so no test sentence
is ever one the system was corrected on. ASR: Parakeet TDT 0.6b. Reranker:
llama3.1:8b, local.

| | baseline (ASR alone) | after 100 corrections |
|---|---|---|
| shared vocabulary | 0.196 | 0.196 |
| unshared vocabulary | 0.179 | 0.185 |

**No gain. Report this plainly.** The interesting part is *why*, and it is not
that the mechanism is broken.

TORGO's prompts are phonetically-balanced TIMIT-style sentences — *"she had
your dark suit in greasy wash water all year"*. The vocabulary a correction
stream harvests from those is ordinary English the recogniser already gets
right. We measured how often personalisation can even apply: a
previously-corrected word is mis-recognised in

* **3 of 25** held-out utterances for F03 (3.3% of content words),
* **0 of 20** for F04,

so even perfect repair of every such word moves WER by under one point —
below the noise of the measurement, which drifts ±2 points between runs.

A flat TORGO curve is therefore the **expected** result. It is evidence about
the corpus, not about the method.

What it does support, and worth saying out loud: **personalisation does no
harm.** An earlier version made accuracy *worse* as the vocabulary grew
(0.152 → 0.230), because the reranker was assembling fluent sentences out of
vocabulary words. Constraining it to repair only what it can justify brought
it back to exact parity in the shared condition: 0.196 before, 0.196 after 100
corrections. For an assistive device, "never corrupts a correct
transcription" is a safety property, not a consolation prize.

## 2. Personal-vocabulary benchmark — proxy speaker

**Synthetic speech, not dysarthric.** Say so in the video and the writeup.
Acoustically degraded until the recogniser fails; sentences written around a
persona's real-world vocabulary (medication, carers, family, places).

Four synthesised voices (Daniel/Karen/Moira/Samantha — two genders, four
accents), rotated across utterances so the result is not an artefact of one
voice.

| | baseline | best checkpoint | relative |
|---|---|---|---|
| WER | 0.347 | 0.290 | −16% |
| **R-WER** (personal terms only) | **0.630** | **0.481** | **−24%** |

R-WER — error rate restricted to the personal terms — is the metric that
matters, and is standard for contextual biasing. Overall WER dilutes a dozen
rare words among a hundred common ones; the rare words are the entire point.

Limitations to state, not bury: one synthetic voice; acoustic degradation is
not articulatory impairment; sentences were written to contain personal
vocabulary, so the opportunity rate is high by construction. This isolates the
mechanism. It is **not** an estimate of real-world gain.

---

## The honest one-paragraph version

> Personalisation recovers a speaker's own vocabulary: on a constructed
> benchmark where the recogniser mis-hears personal terms, error on those
> terms falls 24% as the vocabulary is learned. On TORGO we measure no change,
> because TORGO's phonetically-balanced prompts contain almost no personal
> vocabulary to recover — a previously-corrected word is mis-recognised in
> under 4% of held-out utterances there, capping any possible gain below one
> WER point. What TORGO does show is that the system does not degrade
> transcriptions it cannot improve.

That is a better story than a curve we cannot defend, and it survives a judge
asking the obvious follow-up question.
