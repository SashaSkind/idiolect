"""Idiolect walkers: audio ingestion, personalization, and corpus building."""

import base64;
import json;
import os;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from pipeline.asr { transcribe }
import from pipeline.rerank { rerank as rerank_candidates }
import from models {
    Profile,
    Session,
    Utterance,
    Candidate,
    Correction,
    VocabEntry,
    PronunciationSample,
    TranscriptionResult,
    SessionSnapshot,
    CorrectionResult,
    TrainingPair,
    MetricsCurve,
    Activity,
    VocabularyResult,
    GraphNodeView,
    GraphSnapshot,
    ProfileResult,
}


def now_iso() -> str {
    return datetime.now(timezone.utc).isoformat();
}


def current_profile(profile_id: str = "") -> Profile {
    profiles: list[Profile] = [root -->[?:Profile]];
    for profile in profiles {
        if jid(profile) == profile_id {
            return profile;
        }
    }
    if profiles {
        return profiles[0];
    }
    return (root ++> Profile(name="Personal", created_at=now_iso()))[0] as Profile;
}


def current_session(profile_id: str = "") -> Session {
    profile = current_profile(profile_id);
    sessions: list[Session] = [profile -->[?:Session]];
    if sessions {
        return sessions[-1];
    }
    return (profile ++> Session(started_at=now_iso()))[0] as Session;
}


def clean_term(value: str) -> str {
    return value.strip(".,!?;:\"'()[]{}<>-_/@#$%^&*+=|\\~` ").lower();
}


def session_vocab(session: Session) -> list[VocabEntry] {
    return [session -->[?:VocabEntry]];
}


def session_utterances(session: Session) -> list[Utterance] {
    return [session -->[?:Utterance]];
}


def session_activities(session: Session) -> list[Activity] {
    return [session -->[?:Activity]];
}


def pooled_vocab() -> list[VocabEntry] {
    pooled: list[VocabEntry] = [];
    for profile in [root -->[?:Profile]] {
        for session in [profile -->[?:Session]] {
            for vocab_entry in session_vocab(session) {
                if not vocab_entry.profile_id {
                    vocab_entry.profile_id = jid(profile);
                    vocab_entry.profile_name = profile.name;
                }
                pooled.append(vocab_entry);
            }
        }
    }
    return pooled;
}


walker:pub GetProfiles {
    """List manually managed communication contexts."""
    has active_id: str = "",
        reports: list[ProfileResult] = [];

    can collect with Root entry {
        active = current_profile(self.active_id);
        report ProfileResult(
            profiles=[root -->[?:Profile]],
            active_id=jid(active),
        );
    }
}


walker:pub ManageProfile {
    """Create, rename, or delete a user-selected communication profile."""
    has action: str,
        profile_id: str = "",
        name: str = "",
        reports: list[ProfileResult] = [];

    can manage with Root entry {
        profiles: list[Profile] = [root -->[?:Profile]];
        target: Profile | None = None;
        for profile in profiles {
            if jid(profile) == self.profile_id {
                target = profile;
                break;
            }
        }
        cleaned = self.name.strip();
        active = current_profile(self.profile_id);
        if self.action == "create" and cleaned {
            active = (root ++> Profile(
                name=cleaned,
                created_at=now_iso(),
            ))[0] as Profile;
            active ++> Session(started_at=now_iso());
        } elif self.action == "rename" and target is not None and cleaned {
            target.name = cleaned;
            for session in [target -->[?:Session]] {
                for vocab_entry in session_vocab(session) {
                    vocab_entry.profile_name = cleaned;
                }
            }
            active = target;
        } elif self.action == "delete" and target is not None and len(profiles) > 1 {
            for session in [target -->[?:Session]] {
                for utterance in session_utterances(session) {
                    if os.path.isfile(utterance.audio_path) {
                        os.remove(utterance.audio_path);
                    }
                }
                for vocab_entry in session_vocab(session) {
                    for sample in [vocab_entry -->[?:PronunciationSample]] {
                        if os.path.isfile(sample.audio_path) {
                            os.remove(sample.audio_path);
                        }
                    }
                }
            }
            del target;
            remaining: list[Profile] = [root -->[?:Profile]];
            active = remaining[0];
        }
        report ProfileResult(
            profiles=[root -->[?:Profile]],
            active_id=jid(active),
        );
    }
}


walker:pub Transcribe {
    """Persist browser audio, create hypotheses, and return a personalized pick."""
    has audio_data: str,
        mime_type: str = "audio/webm",
        profile_id: str = "",
        reports: list[TranscriptionResult] = [];

    can process with Root entry {
        session = current_session(self.profile_id);
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f");
        suffix = ".wav" if "wav" in self.mime_type else ".webm";
        audio_path = os.path.join("data", "audio", "utterance-" + stamp + suffix);
        Path(os.path.dirname(audio_path)).mkdir(parents=True, exist_ok=True);

        if self.audio_data.startswith("sample:") {
            # Demo path: a bundled recording, transcribed through exactly the
            # same pipeline as live microphone input, so the demo can show a
            # real impaired voice rather than a presenter imitating one.
            #
            # The bundled file is *copied* rather than referenced. Pointing
            # audio_path at the shared asset looked simpler, but every
            # utterance then owned a file it did not create, and deleting a
            # profile - which removes its utterances' audio - deleted the
            # demo assets for everyone. Copying keeps ownership one-to-one.
            source_path = self.audio_data[7:];
            with open(source_path, "rb") as source_file {
                with open(audio_path, "wb") as audio_file {
                    audio_file.write(source_file.read());
                }
            }
        } else {
            encoded = self.audio_data.split(",", 1)[1] if "," in self.audio_data else self.audio_data;
            with open(audio_path, "wb") as audio_file {
                audio_file.write(base64.b64decode(encoded));
            }
        }

        raw_candidates: list[str] = transcribe(audio_path) as list[str];
        active_profile = current_profile(self.profile_id);
        vocab_nodes = pooled_vocab();
        vocabulary: list[str] = [];
        for item in vocab_nodes {
            weight = 3 if item.profile_id == jid(active_profile) else 1;
            for _ in range(weight) {
                vocabulary.append(item.term);
            }
        }
        utterances = session_utterances(session);
        context: list[str] = [
            item.final_text for item in utterances[-3:] if item.final_text
        ];
        preferred: str = rerank_candidates(
            raw_candidates, vocabulary, context
        ) as str;

        for entry in vocab_nodes {
            if clean_term(entry.term) in preferred.lower() {
                entry.successes += 1;
                session ++> Activity(
                    timestamp=now_iso(),
                    kind="success",
                    title="Recognized " + entry.term,
                    detail=preferred,
                );
            }
        }

        utterance = (
            session ++> Utterance(
                audio_path=audio_path,
                timestamp=now_iso(),
                preferred_text=preferred,
            )
        )[0] as Utterance;
        for (rank, text) in enumerate(raw_candidates) {
            utterance ++> Candidate(text=text, rank=rank, source="parakeet");
        }
        report TranscriptionResult(
            utterance_id=jid(utterance),
            candidates=raw_candidates,
            preferred_text=preferred,
            audio_path=audio_path,
        );
    }
}


walker:pub Rerank {
    """Expose the Track A reranker through a typed Jac walker."""
    has candidates: list[str],
        vocab: list[str] = [],
        context: list[str] = [],
        reports: list[str] = [];

    can choose with Root entry {
        choice: str = rerank_candidates(
            self.candidates, self.vocab, self.context
        ) as str;
        report choice;
    }
}


walker:pub AcceptCorrection {
    """Store a correction and turn novel corrected words into graph vocabulary."""
    has utterance_id: str,
        chosen_text: str,
        original_text: str,
        method: str = "edited",
        profile_id: str = "",
        reports: list[CorrectionResult] = [];

    can accept with Root entry {
        session = current_session(self.profile_id);
        utterance: Utterance | None = None;
        for item in session_utterances(session) {
            if jid(item) == self.utterance_id {
                utterance = item;
                break;
            }
        }
        if utterance is None {
            report CorrectionResult(
                final_text="",
                learned_terms=[],
                vocabulary=pooled_vocab(),
                correction_count=0,
            );
            disengage;
        }

        utterance.final_text = self.chosen_text.strip();
        utterance ++> Correction(
            chosen_text=utterance.final_text,
            method=self.method,
            timestamp=now_iso(),
        );
        session ++> Activity(
            timestamp=now_iso(),
            kind="correction",
            title="Corrected transcript",
            detail=self.original_text + " → " + utterance.final_text,
        );

        original_terms: list[str] = [
            clean_term(word) for word in self.original_text.split() if clean_term(word)
        ];
        learned: list[str] = [];
        for word in utterance.final_text.split() {
            normalized = clean_term(word);
            if normalized and normalized not in original_terms and normalized not in [
                clean_term(term) for term in learned
            ] {
                learned.append(
                    word.strip(".,!?;:\"'()[]{}<>-_/@#$%^&*+=|\\~` ")
                );
            }
        }

        existing = session_vocab(session);
        for term in learned {
            matched: VocabEntry | None = None;
            for entry in existing {
                if clean_term(entry.term) == clean_term(term) {
                    matched = entry;
                    break;
                }
            }
            if matched is not None {
                matched.count += 1;
            } else {
                new_entry = (
                    session ++> VocabEntry(
                        term=term,
                        count=1,
                        first_seen=now_iso(),
                        profile_id=jid(current_profile(self.profile_id)),
                        profile_name=current_profile(self.profile_id).name,
                    )
                )[0] as VocabEntry;
                existing.append(new_entry);
            }
        }

        corrections: list[Correction] = [
            session -->[?:Utterance] -->[?:Correction]
        ];
        report CorrectionResult(
            final_text=utterance.final_text,
            learned_terms=learned,
            vocabulary=pooled_vocab(),
            correction_count=len(corrections),
        );
    }
}


walker:pub GetSession {
    """Return the current visible learning state."""
    has profile_id: str = "",
        reports: list[SessionSnapshot] = [];

    can collect with Root entry {
        session = current_session(self.profile_id);
        utterances = session_utterances(session);
        corrections: list[Correction] = [
            session -->[?:Utterance] -->[?:Correction]
        ];
        sample_count = 0;
        for vocab_entry in session_vocab(session) {
            sample_count += len([vocab_entry -->[?:PronunciationSample]]);
        }
        report SessionSnapshot(
            vocabulary=pooled_vocab(),
            recent_utterances=utterances[-5:],
            activities=session_activities(session)[-10:],
            correction_count=len(corrections),
            training_pair_count=len(corrections) + sample_count,
        );
    }
}


walker:pub BuildTrainingSet {
    """Traverse accepted corrections and export audio/text pairs as JSONL."""
    has output_path: str = "eval/training-set.jsonl",
        profile_id: str = "",
        reports: list[str] = [];

    can export with Root entry {
        session = current_session(self.profile_id);
        rows: list[TrainingPair] = [];
        for utterance in session_utterances(session) {
            if utterance.final_text {
                rows.append(
                    TrainingPair(
                        audio_path=utterance.audio_path,
                        text=utterance.final_text,
                    )
                );
            }
        }
        for vocab_entry in session_vocab(session) {
            for sample in [vocab_entry -->[?:PronunciationSample]] {
                rows.append(
                    TrainingPair(
                        audio_path=sample.audio_path,
                        text=vocab_entry.term,
                    )
                );
            }
        }
        Path(os.path.dirname(self.output_path) or ".").mkdir(parents=True, exist_ok=True);
        with open(self.output_path, "w") as output_file {
            for row in rows {
                output_file.write(
                    json.dumps(
                        {"audio_path": row.audio_path, "text": row.text}
                    )
                    + "\n"
                );
            }
        }
        report self.output_path;
    }
}


walker:pub GetMetrics {
    """Load Track A's cached TORGO evaluation without recomputing it live."""
    has reports: list[MetricsCurve] = [];

    can load with Root entry {
        with open(os.path.join("eval", "curve.json"), "r") as curve_file {
            payload = json.load(curve_file);
        }
        report MetricsCurve(
            corrections=payload["corrections"] as list[int],
            baseline=payload["baseline"] as list[float],
            shared_vocabulary=payload["shared_vocabulary"] as list[float],
            unshared_vocabulary=payload["unshared_vocabulary"] as list[float],
            source=payload["source"] as str,
        );
    }
}


walker:pub ManageVocabulary {
    """Add, rename, pin, or delete a personal vocabulary entry."""
    has action: str,
        target_id: str = "",
        term: str = "",
        profile_id: str = "",
        reports: list[VocabularyResult] = [];

    can manage with Root entry {
        session = current_session(self.profile_id);
        vocabulary = session_vocab(session);
        active_profile = current_profile(self.profile_id);
        target: VocabEntry | None = None;
        for entry in vocabulary {
            if jid(entry) == self.target_id {
                target = entry;
                break;
            }
        }

        cleaned = self.term.strip();
        enrollment_id = "";
        enrollment_term = "";
        if self.action == "add" and cleaned {
            duplicate: VocabEntry | None = None;
            for entry in vocabulary {
                if clean_term(entry.term) == clean_term(cleaned) {
                    duplicate = entry;
                    break;
                }
            }
            if duplicate is not None {
                duplicate.count += 1;
                enrollment_id = jid(duplicate);
                enrollment_term = duplicate.term;
            } else {
                created = (session ++> VocabEntry(
                    term=cleaned,
                    first_seen=now_iso(),
                    profile_id=jid(active_profile),
                    profile_name=active_profile.name,
                    count=1,
                    pinned=True,
                ))[0] as VocabEntry;
                enrollment_id = jid(created);
                enrollment_term = created.term;
            }
            session ++> Activity(
                timestamp=now_iso(),
                kind="vocabulary",
                title="Added " + cleaned,
                detail="Pinned to personal vocabulary",
            );
        } elif self.action == "update" and target is not None and cleaned {
            old_term = target.term;
            target.term = cleaned;
            session ++> Activity(
                timestamp=now_iso(),
                kind="vocabulary",
                title="Renamed " + old_term,
                detail="Now " + cleaned,
            );
        } elif self.action == "toggle_pin" and target is not None {
            target.pinned = not target.pinned;
        } elif self.action == "delete" and target is not None {
            removed_term = target.term;
            for sample in [target -->[?:PronunciationSample]] {
                safe_prefix = os.path.join("data", "audio") + os.sep;
                if sample.audio_path.startswith(safe_prefix) and os.path.isfile(
                    sample.audio_path
                ) {
                    os.remove(sample.audio_path);
                }
            }
            del target;
            session ++> Activity(
                timestamp=now_iso(),
                kind="vocabulary",
                title="Removed " + removed_term,
                detail="Deleted from personal vocabulary",
            );
        }

        report VocabularyResult(
            vocabulary=pooled_vocab(),
            activities=session_activities(session)[-10:],
            enrollment_id=enrollment_id,
            enrollment_term=enrollment_term,
        );
    }
}


walker:pub RecordPronunciation {
    """Attach one spoken enrollment sample to a personal vocabulary term."""
    has target_id: str,
        audio_data: str,
        mime_type: str = "audio/webm",
        profile_id: str = "",
        reports: list[VocabularyResult] = [];

    can save with Root entry {
        session = current_session(self.profile_id);
        target: VocabEntry | None = None;
        for vocab_entry in session_vocab(session) {
            if jid(vocab_entry) == self.target_id {
                target = vocab_entry;
                break;
            }
        }
        if target is None {
            report VocabularyResult(
                vocabulary=pooled_vocab(),
                activities=session_activities(session)[-10:],
            );
            disengage;
        }

        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f");
        suffix = ".wav" if "wav" in self.mime_type else ".webm";
        audio_path = os.path.join("data", "audio", "vocab-" + stamp + suffix);
        Path(os.path.dirname(audio_path)).mkdir(parents=True, exist_ok=True);
        encoded = self.audio_data.split(",", 1)[1] if "," in self.audio_data else self.audio_data;
        with open(audio_path, "wb") as audio_file {
            audio_file.write(base64.b64decode(encoded));
        }
        target ++> PronunciationSample(
            audio_path=audio_path,
            timestamp=now_iso(),
        );
        target.sample_count += 1;
        session ++> Activity(
            timestamp=now_iso(),
            kind="voice",
            title="Recorded " + target.term,
            detail="Voice sample added",
        );
        report VocabularyResult(
            vocabulary=pooled_vocab(),
            activities=session_activities(session)[-10:],
        );
    }
}


walker:pub ResetSession {
    """Delete the current graph subtree and its locally stored recordings."""
    has profile_id: str = "",
        reports: list[bool] = [];

    can reset with Root entry {
        profile = current_profile(self.profile_id);
        sessions: list[Session] = [profile -->[?:Session]];
        for session in sessions {
            for utterance in session_utterances(session) {
                safe_prefix = os.path.join("data", "audio") + os.sep;
                if utterance.audio_path.startswith(safe_prefix) and os.path.isfile(
                    utterance.audio_path
                ) {
                    os.remove(utterance.audio_path);
                }
            }
            for vocab_entry in session_vocab(session) {
                for sample in [vocab_entry -->[?:PronunciationSample]] {
                    safe_prefix = os.path.join("data", "audio") + os.sep;
                    if sample.audio_path.startswith(safe_prefix) and os.path.isfile(
                        sample.audio_path
                    ) {
                        os.remove(sample.audio_path);
                    }
                }
            }
            del session;
        }
        report True;
    }
}


walker:pub GetGraph {
    """Project the persistent session graph into a typed visual snapshot."""
    has profile_id: str = "",
        reports: list[GraphSnapshot] = [];

    can project with Root entry {
        session = current_session(self.profile_id);
        views: list[GraphNodeView] = [
            GraphNodeView(
                node_id=jid(session),
                parent_id="root",
                kind="session",
                label="Current session",
                detail=session.started_at,
                is_new=False,
            )
        ];
        edge_count = 1;

        utterances = session_utterances(session);
        for utterance in utterances {
            views.append(
                GraphNodeView(
                    node_id=jid(utterance),
                    parent_id=jid(session),
                    kind="utterance",
                    label=utterance.final_text or utterance.preferred_text or "Unreviewed speech",
                    detail=utterance.timestamp,
                    is_new=utterance == utterances[-1],
                )
            );
            edge_count += 1;
            for candidate in [utterance -->[?:Candidate]] {
                views.append(
                    GraphNodeView(
                        node_id=jid(candidate),
                        parent_id=jid(utterance),
                        kind="candidate",
                        label=candidate.text,
                        detail="#" + str(candidate.rank + 1),
                    )
                );
                edge_count += 1;
            }
            for correction in [utterance -->[?:Correction]] {
                views.append(
                    GraphNodeView(
                        node_id=jid(correction),
                        parent_id=jid(utterance),
                        kind="correction",
                        label=correction.chosen_text,
                        detail=correction.method,
                        is_new=True,
                    )
                );
                edge_count += 1;
            }
        }
        for entry in session_vocab(session) {
            views.append(
                GraphNodeView(
                    node_id=jid(entry),
                    parent_id=jid(session),
                    kind="vocabulary",
                    label=entry.term,
                    detail=str(entry.successes) + " successful uses",
                )
            );
            edge_count += 1;
            for sample in [entry -->[?:PronunciationSample]] {
                views.append(
                    GraphNodeView(
                        node_id=jid(sample),
                        parent_id=jid(entry),
                        kind="voice",
                        label="Voice sample",
                        detail=sample.timestamp,
                    )
                );
                edge_count += 1;
            }
        }
        for activity in session_activities(session)[-6:] {
            views.append(
                GraphNodeView(
                    node_id=jid(activity),
                    parent_id=jid(session),
                    kind="activity",
                    label=activity.title,
                    detail=activity.kind,
                )
            );
            edge_count += 1;
        }

        report GraphSnapshot(
            nodes=views,
            node_count=len(views) + 1,
            edge_count=edge_count,
        );
    }
}
