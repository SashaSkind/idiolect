"""Idiolect full-stack entry point."""

import from walkers {
    Profile,
    Session,
    Utterance,
    Candidate,
    Correction,
    VocabEntry,
    PronunciationSample,
    TranscriptionResult,
    SessionSnapshot,
    Transcribe,
    Rerank,
    AcceptCorrection,
    GetSession,
    BuildTrainingSet,
    MetricsCurve,
    GetMetrics,
    Activity,
    VocabularyResult,
    GraphNodeView,
    GraphSnapshot,
    ManageVocabulary,
    RecordPronunciation,
    ResetSession,
    GetGraph,
    ProfileResult,
    GetProfiles,
    ManageProfile,
}

cl {
    import ".styles.global.css";
    import from .frontend { IdiolectApp }

    def:pub app() -> JsxElement {
        return <IdiolectApp />;
    }
}
