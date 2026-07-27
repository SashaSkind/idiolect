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
            # Demo path: a bundled recording of real dysarthric speech (TORGO),
            # transcribed through exactly the same pipeline as live microphone
            # input. Lets the demo show a real impaired voice rather than a
            # presenter imitating one.
            audio_path = self.audio_data[7:];
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


def seed_profile(name: str) -> Profile {
    """Find a demo profile by name, or create it. Never touches user profiles."""
    for profile in [root -->[?:Profile]] {
        if profile.name == name {
            return profile;
        }
    }
    return (root ++> Profile(name=name, created_at=now_iso()))[0] as Profile;
}


def seed_session(profile: Profile, started_at: str) -> Session {
    """One session per demo profile, reused on repeat runs."""
    sessions: list[Session] = [profile -->[?:Session]];
    if sessions {
        return sessions[0];
    }
    return (profile ++> Session(started_at=started_at))[0] as Session;
}


def seed_utterance(
    session: Session,
    stamp: str,
    accepted: str,
    candidates: list[str]
) -> Utterance {
    """Create one utterance with its candidates and its correction.

    Idempotent on the accepted text: an utterance whose final_text already
    matches is returned untouched, so re-running the seed never duplicates a
    story beat. Candidate ranks are assigned by position and are therefore
    unique within the utterance, and final_text is written from the same
    string used for the Correction so the two can never disagree.
    """
    for existing in session_utterances(session) {
        if existing.final_text == accepted {
            return existing;
        }
    }

    utterance = (
        session ++> Utterance(
            audio_path="demo/seeded/" + stamp + ".wav",
            timestamp=stamp,
            final_text=accepted,
            preferred_text=accepted,
        )
    )[0] as Utterance;

    rank = 0;
    for text in candidates {
        source = "parakeet";
        if rank == len(candidates) - 1 {
            source = "gemma-audio";
        }
        utterance ++> Candidate(text=text, rank=rank, source=source);
        rank += 1;
    }

    utterance ++> Correction(
        chosen_text=accepted,
        method="picked",
        timestamp=stamp,
    );
    return utterance;
}


def seed_vocab(
    session: Session,
    profile: Profile,
    term: str,
    first_seen: str,
    count: int,
    successes: int
) -> VocabEntry {
    """One VocabEntry per term per profile, updated rather than duplicated."""
    for entry in session_vocab(session) {
        if clean_term(entry.term) == clean_term(term) {
            entry.count = count;
            entry.successes = successes;
            entry.profile_id = jid(profile);
            entry.profile_name = profile.name;
            return entry;
        }
    }
    return (
        session ++> VocabEntry(
            term=term,
            first_seen=first_seen,
            profile_id=jid(profile),
            profile_name=profile.name,
            count=count,
            successes=successes,
        )
    )[0] as VocabEntry;
}


def seed_activity(session: Session, stamp: str, kind: str, title: str, detail: str) -> None {
    """Append an activity unless an identical one is already recorded."""
    for existing in session_activities(session) {
        if existing.timestamp == stamp and existing.title == title {
            return;
        }
    }
    session ++> Activity(timestamp=stamp, kind=kind, title=title, detail=detail);
}


def seed_pronunciation(entry: VocabEntry, stamp: str) -> None {
    """Attach a pronunciation sample and keep sample_count equal to reality."""
    samples: list[PronunciationSample] = [entry -->[?:PronunciationSample]];
    for sample in samples {
        if sample.timestamp == stamp {
            return;
        }
    }
    entry ++> PronunciationSample(
        audio_path="demo/seeded/pron-" + clean_term(entry.term) + ".wav",
        timestamp=stamp,
    );
    entry.sample_count = len([entry -->[?:PronunciationSample]]);
}


walker:pub SeedDemo {
    """Populate a coherent demo graph. Idempotent, and additive only.

    Every visible number in the UI is derived from these nodes rather than
    hardcoded anywhere: corrections come from Correction nodes, the vocabulary
    panel from VocabEntry nodes, sample counts from PronunciationSample nodes,
    and the timeline from Activity nodes. Running this twice changes nothing,
    and profiles the user created themselves are never read or modified.

    The story it tells, in one profile, is the product thesis: 'baclofen' is
    misheard as 'battle fan', corrected once, becomes vocabulary, and is then
    recognised correctly in a later sentence that was never corrected.
    """
    has reports: list[str] = [];

    can seed with Root entry {
        care = seed_profile("Personal Care");
        care_session = seed_session(care, "2026-07-26T09:00:00+00:00");

        # 1. the mishearing that starts the story
        seed_utterance(
            care_session,
            "2026-07-26T09:04:00+00:00",
            "Please remind me to take baclofen",
            [
                "Please remind me to take battle fan",
                "Please remind me to take back low fan",
                "Please remind me to take baclofin",
                "Please remind me to take baclofen",
            ],
        );
        seed_activity(
            care_session,
            "2026-07-26T09:04:00+00:00",
            "correction",
            "Corrected transcript",
            "Please remind me to take battle fan → Please remind me to take baclofen",
        );
        seed_activity(
            care_session,
            "2026-07-26T09:04:05+00:00",
            "vocabulary",
            "Learned baclofen",
            "Added from a correction, no enrolment needed",
        );

        # 2. a carer's name and a British spelling
        seed_utterance(
            care_session,
            "2026-07-26T09:18:00+00:00",
            "Can Nadia bring the nebuliser",
            [
                "Can nadia bring the nebulizer",
                "Can Nadya bring the nebulizer",
                "Can Nadia bring the nebuliser",
                "Can idea bring the nebuliser",
            ],
        );
        seed_activity(
            care_session,
            "2026-07-26T09:18:00+00:00",
            "correction",
            "Corrected transcript",
            "Can nadia bring the nebulizer → Can Nadia bring the nebuliser",
        );
        seed_activity(
            care_session,
            "2026-07-26T09:18:05+00:00",
            "vocabulary",
            "Learned Nadia and nebuliser",
            "Two personal terms from one correction",
        );

        # 3. a place name
        seed_utterance(
            care_session,
            "2026-07-26T10:02:00+00:00",
            "My physio is in Wandsworth",
            [
                "My physio is in wand's worth",
                "My physio is in Wandsworth",
                "My physical is in Wandsworth",
                "My physio is in one's worth",
            ],
        );
        seed_activity(
            care_session,
            "2026-07-26T10:02:00+00:00",
            "correction",
            "Corrected transcript",
            "My physio is in wand's worth → My physio is in Wandsworth",
        );

        # 4. the payoff: a sentence never corrected, using a learned word
        seed_utterance(
            care_session,
            "2026-07-26T14:41:00+00:00",
            "Did I already take my baclofen today",
            [
                "Did I already take my back left in today",
                "Did I already take my baclofen today",
                "Did I already take my bacloven today",
            ],
        );
        seed_activity(
            care_session,
            "2026-07-26T14:41:00+00:00",
            "recognition",
            "Recognised baclofen without being asked",
            "Standard ASR heard 'back left in'; personal vocabulary repaired it",
        );

        # 5. two more accepted utterances, for a credible history
        seed_utterance(
            care_session,
            "2026-07-26T11:20:00+00:00",
            "Doctor Okafor changed my gabapentin",
            [
                "Doctor okay for changed my gaba pentin",
                "Doctor Okafor changed my gabapentin",
                "Doctor of for changed my gabapentin",
            ],
        );
        seed_utterance(
            care_session,
            "2026-07-26T13:05:00+00:00",
            "Bryony is bringing the hoist sling",
            [
                "Briany is bringing the hoist sling",
                "Bryony is bringing the hoist sling",
                "Brian he is bringing the hoist sling",
            ],
        );

        care_terms = [
            ("baclofen", "2026-07-26T09:04:05+00:00", 4, 3),
            ("Nadia", "2026-07-26T09:18:05+00:00", 3, 2),
            ("nebuliser", "2026-07-26T09:18:05+00:00", 2, 1),
            ("Wandsworth", "2026-07-26T10:02:05+00:00", 2, 1),
            ("gabapentin", "2026-07-26T11:20:05+00:00", 2, 1),
            ("Dr. Okafor", "2026-07-26T11:20:05+00:00", 2, 1),
            ("Bryony", "2026-07-26T13:05:05+00:00", 2, 1),
            ("hoist", "2026-07-26T13:05:05+00:00", 1, 0),
            ("Gaviscon", "2026-07-26T12:10:00+00:00", 1, 0),
            ("catheter", "2026-07-26T12:30:00+00:00", 1, 0),
            ("physiotherapy", "2026-07-26T10:02:05+00:00", 1, 0),
        ];
        for (term, seen, count, successes) in care_terms {
            seed_vocab(care_session, care, term, seen, count, successes);
        }

        for entry in session_vocab(care_session) {
            if entry.term == "baclofen" {
                seed_pronunciation(entry, "2026-07-26T09:06:00+00:00");
            }
            if entry.term == "Nadia" {
                seed_pronunciation(entry, "2026-07-26T09:19:00+00:00");
            }
            if entry.term == "Gaviscon" {
                seed_pronunciation(entry, "2026-07-26T12:11:00+00:00");
            }
        }
        seed_activity(
            care_session,
            "2026-07-26T09:06:00+00:00",
            "pronunciation",
            "Recorded how baclofen sounds",
            "One sample, kept on device",
        );

        # A second profile: the same person, a different vocabulary. Switching
        # is manual today; automatic context detection is future work and is
        # not claimed anywhere in the UI.
        work = seed_profile("Work");
        work_session = seed_session(work, "2026-07-26T15:00:00+00:00");
        seed_utterance(
            work_session,
            "2026-07-26T15:12:00+00:00",
            "The reranker runs in Jaclang",
            [
                "The ree ranker runs in jack lang",
                "The reranker runs in Jaclang",
                "The re ranker runs in jaclang",
            ],
        );
        seed_activity(
            work_session,
            "2026-07-26T15:12:00+00:00",
            "correction",
            "Corrected transcript",
            "The ree ranker runs in jack lang → The reranker runs in Jaclang",
        );
        work_terms = [
            ("Idiolect", "2026-07-26T15:02:00+00:00", 3, 2),
            ("Jaclang", "2026-07-26T15:12:00+00:00", 2, 1),
            ("Jaseci", "2026-07-26T15:12:00+00:00", 2, 1),
            ("byLLM", "2026-07-26T15:20:00+00:00", 1, 0),
            ("reranker", "2026-07-26T15:12:00+00:00", 2, 1),
            ("transcription", "2026-07-26T15:25:00+00:00", 1, 0),
            ("Fort Mason", "2026-07-26T15:30:00+00:00", 1, 0),
        ];
        for (term, seen, count, successes) in work_terms {
            seed_vocab(work_session, work, term, seen, count, successes);
        }

        self.reports.append("Personal Care: " + str(len(session_utterances(care_session))) + " utterances, " + str(len(session_vocab(care_session))) + " terms");
        self.reports.append("Work: " + str(len(session_utterances(work_session))) + " utterances, " + str(len(session_vocab(work_session))) + " terms");
        report self.reports;
    }
}


walker:pub ValidateDemo {
    """Check the graph is internally consistent, so the UI cannot disagree with it.

    Every number the interface shows is a traversal of this graph, so the way
    the demo goes wrong is not a broken widget but a graph that quietly
    contradicts itself: a correction whose text differs from its utterance's
    final_text, two candidates sharing a rank, a vocabulary entry claiming
    more pronunciation samples than exist. Each check below corresponds to one
    of those failures, and reports the offending record rather than a bare
    count so it can be found.
    """
    has problems: list[str] = [],
        checked: list[str] = [];

    can validate with Root entry {
        utterance_total = 0;
        correction_total = 0;
        candidate_total = 0;
        vocab_total = 0;
        sample_total = 0;
        activity_total = 0;

        for profile in [root -->[?:Profile]] {
            for session in [profile -->[?:Session]] {
                for utterance in session_utterances(session) {
                    utterance_total += 1;

                    # exactly one correction per accepted utterance, and the
                    # two texts must be the same string
                    corrections: list[Correction] = [utterance -->[?:Correction]];
                    correction_total += len(corrections);
                    if utterance.final_text {
                        if len(corrections) != 1 {
                            self.problems.append(
                                "utterance '" + utterance.final_text
                                + "' has " + str(len(corrections)) + " corrections, expected 1"
                            );
                        }
                        for correction in corrections {
                            if correction.chosen_text != utterance.final_text {
                                self.problems.append(
                                    "final_text '" + utterance.final_text
                                    + "' disagrees with correction '"
                                    + correction.chosen_text + "'"
                                );
                            }
                        }
                    }

                    # candidate ranks must be unique inside one utterance
                    seen_ranks: list[int] = [];
                    candidates: list[Candidate] = [utterance -->[?:Candidate]];
                    candidate_total += len(candidates);
                    if utterance.final_text and not candidates {
                        self.problems.append(
                            "utterance '" + utterance.final_text + "' has no candidates"
                        );
                    }
                    for candidate in candidates {
                        if candidate.rank in seen_ranks {
                            self.problems.append(
                                "duplicate candidate rank " + str(candidate.rank)
                                + " on '" + utterance.final_text + "'"
                            );
                        }
                        seen_ranks.append(candidate.rank);
                    }
                }

                # vocabulary must know which profile owns it, and its
                # advertised sample count must match the real samples
                for entry in session_vocab(session) {
                    vocab_total += 1;
                    if not entry.term.strip() {
                        self.problems.append("vocabulary entry with an empty term");
                    }
                    if entry.profile_id != jid(profile) {
                        self.problems.append(
                            "vocabulary '" + entry.term + "' is not owned by "
                            + profile.name
                        );
                    }
                    samples: list[PronunciationSample] = [entry -->[?:PronunciationSample]];
                    sample_total += len(samples);
                    if entry.sample_count != len(samples) {
                        self.problems.append(
                            "vocabulary '" + entry.term + "' claims "
                            + str(entry.sample_count) + " samples but has "
                            + str(len(samples))
                        );
                    }
                }

                for activity in session_activities(session) {
                    activity_total += 1;
                    if not activity.title.strip() {
                        self.problems.append("activity with no title");
                    }
                }
            }
        }

        # pooled vocabulary must not double-count a term within one profile
        pooled = pooled_vocab();
        pairs: list[str] = [];
        for entry in pooled {
            key = entry.profile_id + "/" + clean_term(entry.term);
            if key in pairs {
                self.problems.append("duplicate pooled vocabulary '" + entry.term + "'");
            }
            pairs.append(key);
        }

        self.checked.append("utterances: " + str(utterance_total));
        self.checked.append("corrections: " + str(correction_total));
        self.checked.append("candidates: " + str(candidate_total));
        self.checked.append("vocabulary: " + str(vocab_total));
        self.checked.append("pronunciation samples: " + str(sample_total));
        self.checked.append("activities: " + str(activity_total));
        self.checked.append("pooled vocabulary: " + str(len(pooled)));
        if self.problems {
            self.checked.append("PROBLEMS: " + str(len(self.problems)));
        } else {
            self.checked.append("all checks passed");
        }
        report self.checked + self.problems;
    }
}
