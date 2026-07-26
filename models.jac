"""Persistent speech-learning graph and typed API views."""

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
        count: int = 1;
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
