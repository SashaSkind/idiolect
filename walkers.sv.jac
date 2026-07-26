"""Idiolect walkers: audio ingestion, personalization, and corpus building."""

import base64;
import json;
import os;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from pipeline.asr { transcribe }
import from pipeline.rerank { rerank as rerank_candidates }
import from models {
    Session,
    Utterance,
    Candidate,
    Correction,
    VocabEntry,
    TranscriptionResult,
    SessionSnapshot,
    CorrectionResult,
    TrainingPair,
    MetricsCurve,
}


def now_iso() -> str {
    return datetime.now(timezone.utc).isoformat();
}


def current_session() -> Session {
    sessions: list[Session] = [root -->[?:Session]];
    if sessions {
        return sessions[-1];
    }
    return (root ++> Session(started_at=now_iso()))[0] as Session;
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


walker:pub Transcribe {
    """Persist browser audio, create hypotheses, and return a personalized pick."""
    has audio_data: str,
        mime_type: str = "audio/webm",
        reports: list[TranscriptionResult] = [];

    can process with Root entry {
        session = current_session();
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f");
        suffix = ".wav" if "wav" in self.mime_type else ".webm";
        audio_path = os.path.join("data", "audio", "utterance-" + stamp + suffix);
        Path(os.path.dirname(audio_path)).mkdir(parents=True, exist_ok=True);

        encoded = self.audio_data.split(",", 1)[1] if "," in self.audio_data else self.audio_data;
        with open(audio_path, "wb") as audio_file {
            audio_file.write(base64.b64decode(encoded));
        }

        raw_candidates: list[str] = transcribe(audio_path) as list[str];
        vocab_nodes = session_vocab(session);
        vocabulary: list[str] = [item.term for item in vocab_nodes];
        utterances = session_utterances(session);
        context: list[str] = [
            item.final_text for item in utterances[-3:] if item.final_text
        ];
        preferred: str = rerank_candidates(
            raw_candidates, vocabulary, context
        ) as str;

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
        reports: list[CorrectionResult] = [];

    can accept with Root entry {
        session = current_session();
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
                vocabulary=session_vocab(session),
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
            vocabulary=session_vocab(session),
            correction_count=len(corrections),
        );
    }
}


walker:pub GetSession {
    """Return the current visible learning state."""
    has reports: list[SessionSnapshot] = [];

    can collect with Root entry {
        session = current_session();
        utterances = session_utterances(session);
        corrections: list[Correction] = [
            session -->[?:Utterance] -->[?:Correction]
        ];
        report SessionSnapshot(
            vocabulary=session_vocab(session),
            recent_utterances=utterances[-5:],
            correction_count=len(corrections),
            training_pair_count=len(corrections),
        );
    }
}


walker:pub BuildTrainingSet {
    """Traverse accepted corrections and export audio/text pairs as JSONL."""
    has output_path: str = "eval/training-set.jsonl",
        reports: list[str] = [];

    can export with Root entry {
        session = current_session();
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
