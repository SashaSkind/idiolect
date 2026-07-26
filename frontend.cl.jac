"""Idiolect judge-facing application shell."""

import from .components.Recorder { Recorder }
import from .components.MetricsChart { MetricsChart }

sv import from walkers {
    VocabEntry,
    Utterance,
    TranscriptionResult,
    SessionSnapshot,
    CorrectionResult,
    MetricsCurve,
    Transcribe,
    AcceptCorrection,
    GetSession,
    BuildTrainingSet,
    GetMetrics,
}


def:pub IdiolectApp() -> JsxElement {
    has phase: str = "ready",
        status_message: str = "Ready when you are",
        transcription: TranscriptionResult | None = None,
        correction_text: str = "",
        vocabulary: list[VocabEntry] = [],
        recent_utterances: list[Utterance] = [],
        correction_count: int = 0,
        training_pair_count: int = 0,
        curve: MetricsCurve | None = None,
        last_learned: list[str] = [],
        accepted_text: str = "",
        error_message: str = "";

    async can with entry {
        await refresh_session();
        metrics_result = root spawn GetMetrics();
        if metrics_result.reports {
            curve = metrics_result.reports[0];
        }
    }

    async def refresh_session -> None {
        session_result = root spawn GetSession();
        if session_result.reports {
            snapshot: SessionSnapshot = session_result.reports[0];
            vocabulary = snapshot.vocabulary;
            recent_utterances = snapshot.recent_utterances;
            correction_count = snapshot.correction_count;
            training_pair_count = snapshot.training_pair_count;
        }
    }

    async def process_audio(audio_data: str, mime_type: str) -> None {
        phase = "processing";
        status_message = "Listening closely…";
        error_message = "";
        accepted_text = "";
        last_learned = [];
        try {
            result = root spawn Transcribe(
                audio_data=audio_data,
                mime_type=mime_type,
            );
            if result.reports {
                transcription = result.reports[0];
                correction_text = transcription.preferred_text;
                phase = "review";
                status_message = "Choose or correct what you said";
            } else {
                error_message = "No transcription came back. Please try once more.";
                phase = "ready";
            }
        } except Exception {
            error_message = "The local speech pipeline could not process that recording.";
            phase = "ready";
        }
    }

    def select_candidate(candidate_text: str) -> None {
        correction_text = candidate_text;
    }

    def edit_correction(event: ChangeEvent) -> None {
        correction_text = event.target.value;
    }

    async def accept_correction -> None {
        if transcription is None or not correction_text.strip() {
            return;
        }
        phase = "saving";
        method = (
            "picked"
            if correction_text in transcription.candidates
            else "edited"
        );
        result = root spawn AcceptCorrection(
            utterance_id=transcription.utterance_id,
            chosen_text=correction_text,
            original_text=transcription.candidates[0],
            method=method,
        );
        if result.reports {
            accepted: CorrectionResult = result.reports[0];
            accepted_text = accepted.final_text;
            last_learned = accepted.learned_terms;
            vocabulary = accepted.vocabulary;
            correction_count = accepted.correction_count;
            training_pair_count = accepted.correction_count;
            phase = "learned";
            status_message = "Learned from this correction";
        } else {
            phase = "review";
            error_message = "That correction was not saved.";
        }
    }

    def reset_recording -> None {
        transcription = None;
        correction_text = "";
        accepted_text = "";
        last_learned = [];
        error_message = "";
        phase = "ready";
        status_message = "Ready for the next utterance";
    }

    async def export_training_set -> None {
        export_result = root spawn BuildTrainingSet();
        if export_result.reports {
            status_message = "Training pairs exported locally";
        }
    }

    return
        <div className="app-shell">
            <header className="topbar">
                <a className="brand" href="#">
                    <span className="brand-mark">
                        <i></i><i></i><i></i><i></i><i></i>
                    </span>
                    <span>Idiolect</span>
                </a>
                <div className="local-pill">
                    <span></span> On-device session
                </div>
            </header>

            <main>
                <section className="hero">
                    <span className="kicker">PERSONAL SPEECH, UNDERSTOOD</span>
                    <h1>Your voice shouldn’t have to<br/>sound standard.</h1>
                    <p>
                        Speak naturally. Correct us when we miss. Idiolect remembers—
                        so every conversation gets easier.
                    </p>
                    <div className="learning-stats">
                        <div><strong>{str(correction_count)}</strong><span>corrections learned</span></div>
                        <div className="divider"></div>
                        <div><strong>{str(len(vocabulary))}</strong><span>personal terms</span></div>
                        <div className="divider"></div>
                        <div><strong>{str(training_pair_count)}</strong><span>training pairs</span></div>
                    </div>
                </section>

                <section className="workspace-grid">
                    <div className="card speech-card">
                        <div className="section-heading">
                            <div>
                                <span className="eyebrow">SPEAK</span>
                                <h2>{status_message}</h2>
                            </div>
                            <span className={"status-dot " + phase}></span>
                        </div>

                        {if phase == "ready" or phase == "processing" {
                            <Recorder
                                disabled={phase == "processing"}
                                onAudio={process_audio}
                            />
                            if phase == "processing" {
                                <div className="processing-row">
                                    <span className="spinner"></span>
                                    <span>Parakeet is generating candidates. Gemma is using your context.</span>
                                </div>
                            }
                        } else {
                            <div className="transcript-panel">
                                <div className="compare-labels">
                                    <span>STANDARD ASR</span>
                                    <span>PERSONALIZED</span>
                                </div>
                                <div className="compare-row">
                                    <p className="baseline-text">
                                        {transcription.candidates[0] if transcription else ""}
                                    </p>
                                    <span className="arrow">→</span>
                                    <p className="personalized-text">
                                        {transcription.preferred_text if transcription else ""}
                                    </p>
                                </div>

                                {if phase == "learned" {
                                    <div className="learned-callout">
                                        <span className="check">✓</span>
                                        <div>
                                            <strong>Saved: “{accepted_text}”</strong>
                                            <p>
                                                {
                                                    "Learned " + ", ".join(last_learned)
                                                    if last_learned
                                                    else "Context reinforced—ready for the next phrase."
                                                }
                                            </p>
                                        </div>
                                    </div>
                                    <button className="primary-button" onClick={reset_recording}>
                                        Record another
                                    </button>
                                } else {
                                    <p className="candidate-prompt">Tap the closest candidate</p>
                                    <div className="candidate-list">
                                        {if transcription {
                                            for (index, candidate) in enumerate(transcription.candidates) {
                                                <button
                                                    key={str(index)}
                                                    className={
                                                        "candidate selected"
                                                        if correction_text == candidate
                                                        else "candidate"
                                                    }
                                                    onClick={lambda {
                                                        select_candidate(candidate);
                                                    }}
                                                >
                                                    <span>{str(index + 1)}</span>
                                                    {candidate}
                                                </button>
                                            }
                                        }}
                                    </div>
                                    <label className="correction-label" htmlFor="correction">
                                        Or correct the transcript
                                    </label>
                                    <textarea
                                        id="correction"
                                        value={correction_text}
                                        onChange={edit_correction}
                                        rows={2}
                                    ></textarea>
                                    <button
                                        className="primary-button"
                                        disabled={phase == "saving" or not correction_text.strip()}
                                        onClick={accept_correction}
                                    >
                                        {"Saving…" if phase == "saving" else "Use this transcript"}
                                    </button>
                                }}
                            </div>
                        }}
                        {if error_message {
                            <p className="inline-error">{error_message}</p>
                        }}
                    </div>

                    <aside className="card vocab-card">
                        <div className="section-heading">
                            <div>
                                <span className="eyebrow">MEMORY</span>
                                <h2>Your vocabulary</h2>
                            </div>
                            <span className="count-badge">{str(len(vocabulary))}</span>
                        </div>
                        <p className="panel-copy">
                            Words learned from your corrections immediately bias the next transcript.
                        </p>
                        <div className="vocab-list">
                            {if not vocabulary {
                                <div className="empty-vocab">
                                    <span>Aa</span>
                                    <p>Correct a transcript and your personal terms will appear here.</p>
                                </div>
                            } else {
                                for entry in vocabulary {
                                    <div key={entry.term} className="vocab-chip">
                                        <span>{entry.term}</span>
                                        <small>×{str(entry.count)}</small>
                                    </div>
                                }
                            }}
                        </div>
                        <div className="recent-block">
                            <h3>Recent accepted speech</h3>
                            {if not recent_utterances {
                                <p className="muted">No accepted utterances yet.</p>
                            } else {
                                for utterance in recent_utterances {
                                    if utterance.final_text {
                                        <p key={utterance.timestamp}>“{utterance.final_text}”</p>
                                    }
                                }
                            }}
                        </div>
                        <button className="text-button" onClick={export_training_set}>
                            Export {str(training_pair_count)} training pairs ↗
                        </button>
                    </aside>
                </section>

                <MetricsChart curve={curve}/>

                <section className="how-it-works">
                    <span className="eyebrow">THE LOOP</span>
                    <h2>No enrollment. Just use it.</h2>
                    <div className="steps">
                        <div><span>01</span><strong>Speak</strong><p>Use your voice naturally.</p></div>
                        <div><span>02</span><strong>Correct</strong><p>Tap or edit the transcript.</p></div>
                        <div><span>03</span><strong>Improve</strong><p>Your graph learns immediately.</p></div>
                    </div>
                </section>
            </main>

            <footer>
                <span>Idiolect</span>
                <span>Built with Jac · Local by design</span>
            </footer>
        </div>;
}
