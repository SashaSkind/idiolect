# Project brief — personalized speech recognition for atypical speech

**Event:** JacHacks SF 2026 (Sun Jul 26, Founders Inc / Fort Mason) + Gemma 4 Challenge
**Purpose of this doc:** everything needed to write the MVP statement, the Devpost writeup, and the pitch. Technical build is being handled in parallel.

---

## 1. The problem

Standard speech recognition fails badly for people with atypical speech — dysarthria, apraxia, stuttering, and speech affected by ALS, cerebral palsy, Parkinson's, Down syndrome, or stroke.

The numbers, from Google Research:

- Typical speech: word error rate (WER) under 10%
- Disordered speech: WER of 50%, sometimes 90%
- Google estimates **250 million people worldwide** have non-standard speech

This is not a small accuracy gap. It is the difference between a usable tool and an unusable one. The people who would benefit most from voice input are the ones most excluded from it.

---

## 2. Why this is still unsolved (the wedge)

Both Google and Apple built solutions. Both are locked away, and Google published why their approach didn't work.

### Google — Project Euphonia / Project Relate

- Trained on 1M+ speech samples across ALS, cerebral palsy, Down syndrome, Parkinson's, stroke, TBI
- **Enrollment: the user records up to 500 phrases** to produce a personalized model
- Features: Listen (live transcription), Repeat (restates in a synthesized voice), Voice Typing into Docs/Gmail, and "Custom Cards" for personal vocabulary (names of loved ones, street names)
- Personalized models stay on the user's device
- Android only; English, with a Hindi pilot

**Google's own retrospective on Relate:**
> personalized models can be very useful, but for many users, recording dozens or hundreds of examples can be challenging. In addition, the personalized models did not always perform well in freeform conversation.

Their response was to give up on personalization and pivot toward speaker-independent models.

### Apple — Listen for Atypical Speech

- On-device ML, ships in iOS 18 / macOS
- **A Siri accessibility toggle**, not a developer framework — no API, no weights, no way to build on it
- **U.S. English only**
- Scoped to Siri commands, not general dictation

### The gap, stated plainly

Enrollment is a tax nobody wants to pay. Google proved this with real users and then walked away from the whole approach rather than fixing the data-collection experience.

**Our thesis: don't ask for enrollment. Make labeling a byproduct of ordinary use.** Someone who depends on this tool to be understood is *already* correcting the transcript. That correction is a perfectly good training label. Capture it.

---

## 3. What we're building

A dictation tool that gets measurably better at understanding one specific person, the more that person uses it.

**The loop:**

1. User speaks
2. System produces several candidate transcriptions
3. A language model re-ranks them using the user's personal vocabulary and recent conversation context
4. User taps the correct one — or corrects a single word — or types it if nothing fits
5. That correction is stored as a labeled `(audio, text)` pair in a personal graph
6. Personal vocabulary immediately biases the next transcription (**no training required**)
7. Accumulated pairs optionally fine-tune a LoRA adapter

No enrollment. No scripted phrases. Nothing leaves the device.

---

## 4. Five ways we beat the incumbents

| # | Gap | Them | Us |
|---|-----|------|-----|
| 1 | **Enrollment** | 500 phrases before anything works | Zero. Labels come from corrections the user was making anyway |
| 2 | **Freeform speech** | Google admits their models fail here | 500 scripted phrases don't contain *your* words. Learning from real use makes coverage match usage by construction |
| 3 | **Static vs. continuous** | Trained once | Never stops adapting. Decisive for ALS, where the voice changes month to month |
| 4 | **Context layer** | Pure acoustic personalization, architected before on-device LLMs. Relate's "Custom Cards" is a static list | An LLM that knows what was said 30 seconds ago, who you're talking to, and what you're typing into |
| 5 | **Language** | Apple: U.S. English only. Google: English + Hindi pilot | Gemma 4 covers 140+ languages |

**#4 is the "why now."** Neither incumbent has retrofitted an LLM context layer — both systems predate the possibility.
**#5 is the "how big."** 250M people, served in one or two languages.
**Lead the pitch with #2**, because the incumbent published the failure themselves.

---

## 5. Architecture (for context — the technical side is being finalized separately)

Three layers. We build exactly one of them.

**Layer 1 — Acoustic hypotheses (pretrained, untouched)**
Whisper large-v3 generates N-best candidates. Gemma 4 E4B's native audio path contributes a second, independent set of hypotheses.

*Why both:* Gemma 4 is **not** a state-of-the-art ASR model, and we should be honest about that. On LibriSpeech-test-other, Whisper large-v3-turbo scores ~11.5% WER vs. ~13.2% for the best Gemma 4 variant; on noisy meeting audio the gap is much wider (~16% vs. ~41%). The accepted framing is that Whisper is better at pure transcription while Gemma 4 is better when the task requires language understanding. So we use each for what it's good at.

**Layer 2 — Personalization (this is the project)**
Gemma 4 re-ranks and rewrites the candidate set using personal vocabulary and conversation context, running locally via Ollama. Orchestrated as a Jac graph: nodes for utterances, candidates, corrections, and vocabulary entries; walkers for transcription, re-ranking, and corpus building. **Zero training. This is the entire working demo.**

**Layer 3 — LoRA adapter (optional)**
Fine-tuned in Colab on the pairs the user generated in the last few hours. A bonus, not the spine.

### Anticipating the obvious judge question

*"Wouldn't an unpersonalized state-of-the-art model just beat your personalized weaker one?"*

For typical speech, yes. **For atypical speech the relationship inverts, and that inversion is the entire reason this niche exists.** A 2-point base-model gap is noise next to a 40-point disorder gap. Google demonstrated personalization succeeding on as little as 3–4 minutes of speech. On typical speech, model quality dominates; on atypical speech, personalization dominates by an order of magnitude.

We prove it on stage by benchmarking against Whisper large-v3 — the actual state of the art — not a strawman.

---

## 6. MVP scope

**In:**
- Record → candidates → correct → store
- Personal vocabulary biasing (the day-one win, visible in minutes)
- Live WER counter, before vs. after
- Runs entirely locally

**Out (say so explicitly rather than half-building):**
- Accounts, auth, settings
- Mobile app — web UI only
- Multi-user, deployment, persistence beyond the session

**Optional if time allows:**
- LoRA adapter swapped in live

---

## 7. Demo narrative (4 minutes)

1. Play atypical speech. Show what standard ASR outputs. It's garbage.
2. *"Google spent seven years on this. Their app asked users to record 500 phrases. Users quit. So Google gave up on personalization entirely."*
3. Correct three utterances live. 60 seconds.
4. WER counter drops.
5. **Close on privacy:** nothing left this laptop. Disordered speech is medical data — it should never touch a server.

---

## 8. Honesty constraint

We can't obtain real dysarthric speech data today (the Speech Accessibility Project corpus requires a signed data use agreement). We will use a proxy speaker and **say so explicitly in the demo**. JacHacks Rule 8 makes misrepresentation a disqualification, and judges respect a named limitation more than a fudge.

Best proxy: a teammate whose accent the base models genuinely struggle with. That's a real atypical-speech case, not a simulation.

---

## 9. Submission constraints

**JacHacks SF**
- 40% of the codebase must be Jac (hard eligibility rule)
- All coding between 10:45 AM and 7:15 PM — **they check the repo**
- Partial submission due 5:50 PM, final 7:15 PM, on Devpost
- Max 4 people per team, one project per team
- Tracks to select: **Social Impact** (primary) and **Best Use of Jaclang**

**Gemma 4 Challenge**
- Tracks: **Native Audio & Voice** (Gemma's audio path generates hypotheses) and **Edge / On-Device** (fully local, privacy-first)
- Judging explicitly weights the story and the writeup alongside technical execution

---

## 10. Open questions for you

1. One-sentence MVP statement — what is the single claim we're proving today?
2. Product name.
3. Which persona do we anchor on in the pitch: ALS (progressive, most technically novel, existing voice-banking community) or general dysarthria (broader, easier to explain)?
4. How do we phrase the proxy-speaker disclosure so it reads as rigor rather than a caveat?

---

## Sources

- Google Research, "Responsible AI at Google Research: AI for Social Good" — Euphonia WER figures, the 3–4 minute personalization result, and the Relate retrospective
- Google Project Relate coverage — 500-phrase enrollment, feature set, Custom Cards, on-device models
- Apple Newsroom + Apple Support — Listen for Atypical Speech, U.S. English limitation
- Open ASR Leaderboard benchmarks of Gemma 4 E2B/E4B/12B vs. Whisper
- Speech Accessibility Project (UIUC) — 400+ hours, 190k+ utterances, 500+ speakers, five etiologies
