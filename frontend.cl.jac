"""Idiolect judge-facing application shell."""

import from .components.Recorder { Recorder }
import from .components.MetricsChart { MetricsChart }
import from .components.GraphPanel { GraphPanel }
import from .components.ActivityTimeline { ActivityTimeline }

sv import from walkers {
    Profile,
    ProfileResult,
    Activity,
    VocabEntry,
    Utterance,
    TranscriptionResult,
    SessionSnapshot,
    CorrectionResult,
    MetricsCurve,
    VocabularyResult,
    GraphSnapshot,
    Transcribe,
    AcceptCorrection,
    GetSession,
    BuildTrainingSet,
    GetMetrics,
    ManageVocabulary,
    RecordPronunciation,
    ResetSession,
    GetGraph,
    GetProfiles,
    ManageProfile,
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
        graph: GraphSnapshot | None = None,
        activities: list[Activity] = [],
        last_learned: list[str] = [],
        accepted_text: str = "",
        error_message: str = "",
        vocab_input: str = "",
        editing_vocab_id: str = "",
        editing_vocab_term: str = "",
        selected_word: int = -1,
        replacement_word: str = "",
        reset_armed: bool = False,
        show_insights: bool = False,
        enrollment_id: str = "",
        enrollment_term: str = "",
        enrollment_saving: bool = False,
        profiles: list[Profile] = [],
        active_profile_id: str = "",
        profile_name: str = "",
        show_profile_tools: bool = False,
        show_voice_settings: bool = False,
        voice_rate: float = 1.0,
        voice_pitch: float = 1.0,
        voice_style: str = "Natural",
        voice_preview_text: str = "Your voice deserves to be understood.",
        available_voices: list[any] = [],
        selected_voice_name: str = "";

    async can with entry {
        profile_result = root spawn GetProfiles();
        if profile_result.reports {
            loaded: ProfileResult = profile_result.reports[0];
            profiles = loaded.profiles;
            active_profile_id = loaded.active_id;
        }
        load_system_voices();
        speechSynthesis.onvoiceschanged = load_system_voices;
        await refresh_session();
        metrics_result = root spawn GetMetrics();
        if metrics_result.reports {
            curve = metrics_result.reports[0];
        }
        await refresh_graph();
    }

    async def refresh_session -> None {
        session_result = root spawn GetSession(profile_id=active_profile_id);
        if session_result.reports {
            snapshot: SessionSnapshot = session_result.reports[0];
            vocabulary = snapshot.vocabulary;
            recent_utterances = snapshot.recent_utterances;
            correction_count = snapshot.correction_count;
            training_pair_count = snapshot.training_pair_count;
            activities = snapshot.activities;
        }
    }

    async def refresh_graph -> None {
        graph_result = root spawn GetGraph(profile_id=active_profile_id);
        if graph_result.reports {
            graph = graph_result.reports[0];
        }
    }

    async def process_audio(audio_data: str, mime_type: str) -> None {
        phase = "processing";
        status_message = "Listening closely…";
        error_message = "";
        accepted_text = "";
        last_learned = [];
        selected_word = -1;
        replacement_word = "";
        try {
            result = root spawn Transcribe(
                audio_data=audio_data,
                mime_type=mime_type,
                profile_id=active_profile_id,
            );
            if result.reports {
                transcription = result.reports[0];
                correction_text = transcription.preferred_text;
                phase = "review";
                status_message = "Choose or correct what you said";
                await refresh_graph();
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

    def select_word(index: int, word: str) -> None {
        selected_word = index;
        replacement_word = word;
    }

    def edit_replacement(event: ChangeEvent) -> None {
        replacement_word = event.target.value;
    }

    def apply_word_replacement -> None {
        words = correction_text.split();
        if selected_word >= 0 and selected_word < len(words) and replacement_word.strip() {
            words[selected_word] = replacement_word.strip();
            correction_text = " ".join(words);
            selected_word = -1;
            replacement_word = "";
        }
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
            profile_id=active_profile_id,
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
            await refresh_session();
            await refresh_graph();
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
        selected_word = -1;
        replacement_word = "";
        error_message = "";
        phase = "ready";
        status_message = "Ready for the next utterance";
    }

    async def export_training_set -> None {
        export_result = root spawn BuildTrainingSet(profile_id=active_profile_id);
        if export_result.reports {
            status_message = "Training pairs exported locally";
        }
    }

    def edit_vocab_input(event: ChangeEvent) -> None {
        vocab_input = event.target.value;
    }

    def edit_vocab_term(event: ChangeEvent) -> None {
        editing_vocab_term = event.target.value;
    }

    def begin_vocab_edit(vocab_entry: VocabEntry) -> None {
        editing_vocab_id = jid(vocab_entry);
        editing_vocab_term = vocab_entry.term;
    }

    def cancel_vocab_edit -> None {
        editing_vocab_id = "";
        editing_vocab_term = "";
    }

    async def manage_vocab(action: str, target_id: str = "", term: str = "") -> None {
        result = root spawn ManageVocabulary(
            action=action,
            target_id=target_id,
            term=term,
            profile_id=active_profile_id,
        );
        if result.reports {
            managed: VocabularyResult = result.reports[0];
            vocabulary = managed.vocabulary;
            activities = managed.activities;
            vocab_input = "";
            cancel_vocab_edit();
            if action == "add" and managed.enrollment_id {
                enrollment_id = managed.enrollment_id;
                enrollment_term = managed.enrollment_term;
            }
            await refresh_graph();
        }
    }

    async def add_vocab(event: FormEvent) -> None {
        event.preventDefault();
        if vocab_input.strip() {
            await manage_vocab("add", term=vocab_input);
        }
    }

    async def save_pronunciation(audio_data: str, mime_type: str) -> None {
        if not enrollment_id {
            return;
        }
        enrollment_saving = True;
        result = root spawn RecordPronunciation(
            target_id=enrollment_id,
            audio_data=audio_data,
            mime_type=mime_type,
            profile_id=active_profile_id,
        );
        if result.reports {
            saved: VocabularyResult = result.reports[0];
            vocabulary = saved.vocabulary;
            activities = saved.activities;
            enrollment_id = "";
            enrollment_term = "";
            enrollment_saving = False;
            status_message = "Voice sample added";
            await refresh_session();
            await refresh_graph();
        } else {
            enrollment_saving = False;
            error_message = "The voice sample could not be saved.";
        }
    }

    def skip_pronunciation -> None {
        enrollment_id = "";
        enrollment_term = "";
        enrollment_saving = False;
    }

    async def reset_demo -> None {
        if not reset_armed {
            reset_armed = True;
            return;
        }
        reset_result = root spawn ResetSession(profile_id=active_profile_id);
        if reset_result.reports {
            reset_armed = False;
            reset_recording();
            await refresh_session();
            await refresh_graph();
            status_message = "Demo reset — ready when you are";
        }
    }

    def open_insights -> None {
        show_insights = True;
    }

    def close_insights -> None {
        show_insights = False;
    }

    def edit_profile_name(event: ChangeEvent) -> None {
        profile_name = event.target.value;
    }

    async def switch_profile(event: ChangeEvent) -> None {
        active_profile_id = event.target.value;
        reset_recording();
        enrollment_id = "";
        await refresh_session();
        await refresh_graph();
    }

    async def manage_profile(action: str) -> None {
        result = root spawn ManageProfile(
            action=action,
            profile_id=active_profile_id,
            name=profile_name,
        );
        if result.reports {
            managed: ProfileResult = result.reports[0];
            profiles = managed.profiles;
            active_profile_id = managed.active_id;
            profile_name = "";
            show_profile_tools = False;
            reset_recording();
            await refresh_session();
            await refresh_graph();
        }
    }

    async def create_profile(event: FormEvent) -> None {
        event.preventDefault();
        if profile_name.strip() {
            await manage_profile("create");
        }
    }

    def toggle_profile_tools -> None {
        show_profile_tools = not show_profile_tools;
        profile_name = "";
    }

    def open_voice_settings -> None {
        load_system_voices();
        show_voice_settings = True;
    }

    def close_voice_settings -> None {
        speechSynthesis.cancel();
        show_voice_settings = False;
    }

    def choose_voice_style(style: str) -> None {
        voice_style = style;
        if style == "Clear" {
            voice_rate = 0.88;
            voice_pitch = 1.0;
        } elif style == "Warm" {
            voice_rate = 0.94;
            voice_pitch = 0.88;
        } else {
            voice_rate = 1.0;
            voice_pitch = 1.0;
        }
    }

    def edit_voice_rate(event: ChangeEvent) -> None {
        voice_rate = float(event.target.value);
    }

    def edit_voice_pitch(event: ChangeEvent) -> None {
        voice_pitch = float(event.target.value);
    }

    def edit_voice_preview(event: ChangeEvent) -> None {
        voice_preview_text = event.target.value;
    }

    def load_system_voices -> None {
        system_voices = Array.from(speechSynthesis.getVoices());
        curated: list[any] = [];
        for target_group in ["Feminine", "Masculine"] {
            for system_voice in system_voices {
                if voice_group(system_voice.name) == target_group {
                    curated.append(system_voice);
                    break;
                }
            }
        }
        for system_voice in system_voices {
            if len(curated) < 2 and system_voice not in curated {
                curated.append(system_voice);
            }
        }
        available_voices = curated[:2];
        if available_voices and not selected_voice_name {
            selected_voice_name = available_voices[0].name;
        }
    }

    def voice_group(name: str) -> str {
        lowered = name.lower();
        feminine_names = [
            "samantha", "victoria", "karen", "moira", "tessa", "fiona",
            "ava", "allison", "susan", "zira", "hazel", "female",
        ];
        masculine_names = [
            "alex", "daniel", "fred", "tom", "ralph", "aaron",
            "david", "mark", "george", "male",
        ];
        for hint in feminine_names {
            if hint in lowered {
                return "Feminine";
            }
        }
        for hint in masculine_names {
            if hint in lowered {
                return "Masculine";
            }
        }
        return "Other";
    }

    def select_system_voice(name: str) -> None {
        selected_voice_name = name;
    }

    def select_system_voice_event(event: MouseEvent) -> None {
        selected_voice_name = event.currentTarget.dataset.voice;
    }

    def preview_voice -> None {
        speechSynthesis.cancel();
        utterance = new(SpeechSynthesisUtterance, voice_preview_text);
        utterance.rate = voice_rate;
        utterance.pitch = voice_pitch;
        for system_voice in available_voices {
            if system_voice.name == selected_voice_name {
                utterance.voice = system_voice;
                break;
            }
        }
        speechSynthesis.speak(utterance);
    }

    return
        <div className="app-shell">
            <header className="topbar">
                <a className="brand" href="#">
                    <img className="brand-logo" src="/assets/idiolect-mark.svg" alt=""/>
                    <span>Idiolect</span>
                </a>
                <div className="header-actions">
                    <div className="profile-switcher">
                        <label htmlFor="profile-select">PROFILE</label>
                        <select
                            id="profile-select"
                            value={active_profile_id}
                            onChange={switch_profile}
                        >
                            {for profile in profiles {
                                <option key={jid(profile)} value={jid(profile)}>
                                    {profile.name}
                                </option>
                            }}
                        </select>
                        <button
                            className="profile-settings-button"
                            title="Manage profiles"
                            onClick={toggle_profile_tools}
                        >•••</button>
                        {if show_profile_tools {
                            <div className="profile-popover">
                                <strong>Manage profiles</strong>
                                <form onSubmit={create_profile}>
                                    <input
                                        aria-label="Profile name"
                                        placeholder="Profile name"
                                        value={profile_name}
                                        onChange={edit_profile_name}
                                    />
                                    <button type="submit" disabled={not profile_name.strip()}>
                                        Create
                                    </button>
                                </form>
                                <div className="profile-manage-actions">
                                    <button
                                        disabled={not profile_name.strip()}
                                        onClick={lambda { manage_profile("rename"); }}
                                    >Rename current</button>
                                    <button
                                        className="danger-link"
                                        disabled={len(profiles) <= 1}
                                        onClick={lambda { manage_profile("delete"); }}
                                    >Delete current</button>
                                </div>
                            </div>
                        }}
                    </div>
                    <div className="local-pill">
                        <span></span> On-device session
                    </div>
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
                        <div
                            className="stat-with-tooltip"
                            tabIndex={0}
                            aria-describedby="pooled-terms-help"
                        >
                            <strong>{str(len(vocabulary))}</strong>
                            <span>pooled terms <i className="info-icon" aria-hidden="true">i</i></span>
                            <span id="pooled-terms-help" className="glass-tooltip" role="tooltip">
                                Words from every profile. Your active profile gets
                                strong preference; other profiles get a lighter bias.
                            </span>
                        </div>
                        <div className="divider"></div>
                        <div
                            className="stat-with-tooltip"
                            tabIndex={0}
                            aria-describedby="training-pairs-help"
                        >
                            <strong>{str(training_pair_count)}</strong>
                            <span>training pairs <i className="info-icon" aria-hidden="true">i</i></span>
                            <span id="training-pairs-help" className="glass-tooltip" role="tooltip">
                                Saved audio matched with accepted text, including
                                corrections and pronunciation samples.
                            </span>
                        </div>
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
                                        Correct one word, or edit the full transcript
                                    </label>
                                    <div className="word-editor">
                                        <div className="word-tokens">
                                            {for (index, word) in enumerate(correction_text.split()) {
                                                <button
                                                    key={str(index) + word}
                                                    className={
                                                        "word-token active"
                                                        if selected_word == index
                                                        else "word-token"
                                                    }
                                                    onClick={lambda {
                                                        select_word(index, word);
                                                    }}
                                                >
                                                    {word}
                                                </button>
                                            }}
                                        </div>
                                        {if selected_word >= 0 {
                                            <div className="word-replace-row">
                                                <input
                                                    aria-label="Replacement word"
                                                    value={replacement_word}
                                                    onChange={edit_replacement}
                                                />
                                                <button onClick={apply_word_replacement}>Replace word</button>
                                            </div>
                                        }}
                                    </div>
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
                        <button
                            className="voice-settings-gear"
                            title="Voice personalization"
                            aria-label="Open voice personalization"
                            onClick={open_voice_settings}
                        >⚙</button>
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
                            Active-profile terms receive a strong bias. Tagged
                            terms from other profiles remain available with a lighter bias.
                        </p>
                        <form className="vocab-add" onSubmit={add_vocab}>
                            <input
                                aria-label="Add a personal term"
                                placeholder="Add a term manually"
                                value={vocab_input}
                                onChange={edit_vocab_input}
                            />
                            <button disabled={not vocab_input.strip()} type="submit">Add</button>
                        </form>
                        {if enrollment_id {
                            <div className="enrollment-card">
                                <span className="eyebrow">VOICE SAMPLE</span>
                                <h3>Now say “{enrollment_term}”</h3>
                                <p>
                                    Record one clear pronunciation so this term
                                    becomes an audio-and-text training pair.
                                </p>
                                <Recorder
                                    disabled={enrollment_saving}
                                    onAudio={save_pronunciation}
                                />
                                <button className="skip-enrollment" onClick={skip_pronunciation}>
                                    Skip for now
                                </button>
                            </div>
                        }}
                        <div className="vocab-list">
                            {if not vocabulary {
                                <div className="empty-vocab">
                                    <span>Aa</span>
                                    <p>Correct a transcript and your personal terms will appear here.</p>
                                </div>
                            } else {
                                for vocab_entry in vocabulary {
                                    <div
                                        key={jid(vocab_entry)}
                                        className={
                                            "vocab-item"
                                            if vocab_entry.profile_id == active_profile_id
                                            else "vocab-item cross-profile"
                                        }
                                    >
                                        {if editing_vocab_id == jid(vocab_entry) {
                                            <div className="vocab-edit-row">
                                                <input value={editing_vocab_term} onChange={edit_vocab_term}/>
                                                <button
                                                    onClick={lambda {
                                                        manage_vocab("update", jid(vocab_entry), editing_vocab_term);
                                                    }}
                                                >Save</button>
                                                <button onClick={cancel_vocab_edit}>Cancel</button>
                                            </div>
                                        } else {
                                            <div className="vocab-term">
                                                <span className="pin-indicator">{"◆" if vocab_entry.pinned else "◇"}</span>
                                                <strong>
                                                    {vocab_entry.term}
                                                    <em className="profile-tag">{vocab_entry.profile_name}</em>
                                                </strong>
                                                <small>
                                                    {str(vocab_entry.sample_count)} voice sample
                                                    {"" if vocab_entry.sample_count == 1 else "s"}
                                                    {
                                                        " · strong preference"
                                                        if vocab_entry.profile_id == active_profile_id
                                                        else " · light preference"
                                                    }
                                                </small>
                                            </div>
                                            if vocab_entry.profile_id == active_profile_id {
                                                <div className="vocab-actions">
                                                    <button
                                                        title="Pin term"
                                                        onClick={lambda {
                                                            manage_vocab("toggle_pin", jid(vocab_entry));
                                                        }}
                                                    >{"Unpin" if vocab_entry.pinned else "Pin"}</button>
                                                    <button onClick={lambda { begin_vocab_edit(vocab_entry); }}>Edit</button>
                                                    <button
                                                        className="danger-link"
                                                        onClick={lambda {
                                                            manage_vocab("delete", jid(vocab_entry));
                                                        }}
                                                    >Delete</button>
                                                </div>
                                            } else {
                                                <span className="borrowed-label">FROM POOL</span>
                                            }
                                        }}
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
                        <button
                            className={"reset-button armed" if reset_armed else "reset-button"}
                            onClick={reset_demo}
                        >
                            {"Click again to erase demo data" if reset_armed else "Reset demo session"}
                        </button>
                    </aside>
                </section>

                <section className="insight-launcher card">
                    <div>
                        <span className="eyebrow">UNDER THE HOOD</span>
                        <h2>See how Idiolect learns</h2>
                        <p>
                            Open a dedicated view of the live Jac graph and the
                            evidence behind the personalization loop.
                        </p>
                    </div>
                    <button className="insight-button" onClick={open_insights}>
                        Open graph &amp; evidence →
                    </button>
                </section>

                <section className="history-grid">
                    <ActivityTimeline activities={activities}/>
                </section>

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

            {if show_insights {
                <div className="insights-screen">
                    <header className="insights-header">
                        <div>
                            <span className="eyebrow">IDIOLECT INSIGHTS</span>
                            <h1>Graph &amp; evidence</h1>
                        </div>
                        <button onClick={close_insights}>← Back to the demo</button>
                    </header>
                    <main className="insights-content">
                        <GraphPanel snapshot={graph}/>
                        <MetricsChart curve={curve}/>
                    </main>
                </div>
            }}

            {if show_voice_settings {
                <div className="voice-settings-screen">
                    <header className="insights-header">
                        <div>
                            <span className="eyebrow">TEXT TO SPEECH</span>
                            <h1>Voice personalization</h1>
                        </div>
                        <button onClick={close_voice_settings}>← Back to the demo</button>
                    </header>
                    <main className="voice-settings-content">
                        <section className="card voice-preview-card">
                            <span className="eyebrow">YOUR OUTPUT VOICE</span>
                            <h2>Choose how accepted text sounds</h2>
                            <p>
                                These settings use your browser’s on-device voices
                                and do not change the Track A transcription pipeline.
                            </p>
                            <div className="voice-style-grid">
                                {for style in ["Natural", "Clear", "Warm"] {
                                    <button
                                        key={style}
                                        className={
                                            "voice-style active"
                                            if voice_style == style
                                            else "voice-style"
                                        }
                                        onClick={lambda { choose_voice_style(style); }}
                                    >
                                        <span className="voice-style-icon">◖))</span>
                                        <strong>{style}</strong>
                                    </button>
                                }}
                            </div>
                            <div className="system-voices">
                                <div className="voice-list-heading">
                                    <div>
                                        <span className="eyebrow">SYSTEM VOICES</span>
                                        <h3>Choose a voice</h3>
                                    </div>
                                    <span>2 simple choices</span>
                                </div>
                                {if not available_voices {
                                    <p className="muted">
                                        Your browser has not loaded its installed voices yet.
                                    </p>
                                } else {
                                    <div className="voice-choice-grid">
                                        {for (voice_index, system_voice) in enumerate(available_voices) {
                                            <button
                                                key={system_voice.name + system_voice.lang}
                                                className={
                                                    "system-voice active"
                                                    if selected_voice_name == system_voice.name
                                                    else "system-voice"
                                                }
                                                data-voice={system_voice.name}
                                                onClick={select_system_voice_event}
                                            >
                                                <strong>Voice {str(voice_index + 1)}</strong>
                                                <span>Preview to choose</span>
                                            </button>
                                        }}
                                    </div>
                                }}
                            </div>
                            <label className="voice-slider">
                                <span>Speaking rate <strong>{str(round(voice_rate, 2))}×</strong></span>
                                <input
                                    type="range"
                                    min="0.6"
                                    max="1.4"
                                    step="0.05"
                                    value={voice_rate}
                                    onChange={edit_voice_rate}
                                />
                            </label>
                            <label className="voice-slider">
                                <span>Pitch <strong>{str(round(voice_pitch, 2))}</strong></span>
                                <input
                                    type="range"
                                    min="0.6"
                                    max="1.4"
                                    step="0.05"
                                    value={voice_pitch}
                                    onChange={edit_voice_pitch}
                                />
                            </label>
                            <label className="voice-preview-label" htmlFor="voice-preview">
                                Preview text
                            </label>
                            <textarea
                                id="voice-preview"
                                rows={3}
                                value={voice_preview_text}
                                onChange={edit_voice_preview}
                            ></textarea>
                            <button
                                className="primary-button"
                                disabled={not voice_preview_text.strip()}
                                onClick={preview_voice}
                            >▶ Test this voice</button>
                        </section>
                    </main>
                </div>
            }}
        </div>;
}
