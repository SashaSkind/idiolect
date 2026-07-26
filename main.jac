"""Idiolect full-stack entry point."""

import from walkers {
    Session,
    Utterance,
    Candidate,
    Correction,
    VocabEntry,
    TranscriptionResult,
    SessionSnapshot,
    Transcribe,
    Rerank,
    AcceptCorrection,
    GetSession,
    BuildTrainingSet,
    MetricsCurve,
    GetMetrics,
}

cl {
    import ".styles.global.css";
    import from .frontend { IdiolectApp }

    def:pub app() -> JsxElement {
        return <IdiolectApp />;
    }
}
