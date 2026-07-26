"""Human-readable history derived from graph Activity nodes."""

sv import from ..walkers { Activity }


def format_time(timestamp: str) -> str {
    if "T" in timestamp {
        return timestamp.split("T", 1)[1][:5];
    }
    return timestamp[:5];
}


def:pub ActivityTimeline(activities: list[Activity]) -> JsxElement {
    return
        <section className="card history-card">
            <div className="section-heading">
                <div>
                    <span className="eyebrow">LEARNING HISTORY</span>
                    <h2>What Idiolect remembers</h2>
                </div>
                <span className="count-badge">{str(len(activities))}</span>
            </div>
            <div className="timeline">
                {if not activities {
                    <div className="timeline-empty">
                        Correct a phrase or add vocabulary to create the first event.
                    </div>
                } else {
                    for activity in activities {
                        <div key={activity.timestamp + activity.title} className="timeline-item">
                            <span className={"timeline-icon " + activity.kind}></span>
                            <div>
                                <strong>{activity.title}</strong>
                                <p>{activity.detail}</p>
                            </div>
                            <time>{format_time(activity.timestamp)}</time>
                        </div>
                    }
                }}
            </div>
        </section>;
}

