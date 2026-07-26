"""Persistent speech-learning graph and typed API views."""

node Profile {
    has name: str,
        created_at: str;
}

node Session {
    has started_at: str;
}

node Utterance {
    has audio_path: str,
        timestamp: str,
        final_text: str = "",
        preferred_text: str = "";
}

node Candidate {
    has text: str,
        rank: int,
        source: str = "parakeet";
}

node Correction {
    has chosen_text: str,
        method: str,
        timestamp: str;
}

node VocabEntry {
    has term: str,
        first_seen: str,
        profile_id: str = "",
        profile_name: str = "Personal",
        count: int = 1,
        successes: int = 0,
        sample_count: int = 0,
        pinned: bool = False;
}

node PronunciationSample {
    has audio_path: str,
        timestamp: str;
}

node Activity {
    has timestamp: str,
        kind: str,
        title: str,
        detail: str = "";
}

obj TranscriptionResult {
    has utterance_id: str,
        candidates: list[str],
        preferred_text: str,
        audio_path: str;
}

obj SessionSnapshot {
    has vocabulary: list[VocabEntry],
        recent_utterances: list[Utterance],
        activities: list[Activity],
        correction_count: int,
        training_pair_count: int;
}

obj CorrectionResult {
    has final_text: str,
        learned_terms: list[str],
        vocabulary: list[VocabEntry],
        correction_count: int;
}

obj TrainingPair {
    has audio_path: str,
        text: str;
}

obj MetricsCurve {
    has corrections: list[int],
        baseline: list[float],
        shared_vocabulary: list[float],
        unshared_vocabulary: list[float],
        source: str;
}

obj VocabularyResult {
    has vocabulary: list[VocabEntry],
        activities: list[Activity],
        enrollment_id: str = "",
        enrollment_term: str = "";
}

obj GraphNodeView {
    has node_id: str,
        parent_id: str,
        kind: str,
        label: str,
        detail: str,
        is_new: bool = False;
}

obj GraphSnapshot {
    has nodes: list[GraphNodeView],
        node_count: int,
        edge_count: int;
}

obj ProfileResult {
    has profiles: list[Profile],
        active_id: str;
}
