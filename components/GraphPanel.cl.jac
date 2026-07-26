"""A visible projection of the live Jac speech graph."""

sv import from ..walkers { GraphSnapshot }


def:pub GraphPanel(snapshot: GraphSnapshot | None) -> JsxElement {
    return
        <section className="card graph-card">
            <div className="section-heading">
                <div>
                    <span className="eyebrow">JAC GRAPH</span>
                    <h2>Learning, node by node</h2>
                </div>
                <span className="graph-count">
                    {
                        str(snapshot.node_count) + " nodes · " +
                        str(snapshot.edge_count) + " edges"
                        if snapshot
                        else "Loading graph…"
                    }
                </span>
            </div>
            <p className="panel-copy">
                Every recording, hypothesis, correction, and personal term is a
                persistent node connected to this session.
            </p>
            {if snapshot is None or not snapshot.nodes {
                <div className="graph-empty">The graph will appear after the session loads.</div>
            } else {
                <div className="graph-stage">
                    <div className="graph-root graph-node">
                        <small>ROOT</small>
                        <strong>Persistent graph</strong>
                    </div>
                    <div className="graph-stem"></div>
                    {for node in snapshot.nodes {
                        <div
                            key={node.node_id}
                            className={
                                "graph-node graph-" + node.kind +
                                (" graph-new" if node.is_new else "")
                            }
                            title={node.detail}
                        >
                            <small>{node.kind.upper()}</small>
                            <strong>{node.label}</strong>
                            <span>{node.detail}</span>
                        </div>
                    }}
                </div>
                <div className="graph-legend">
                    <span><i className="legend-node utterance"></i>Utterance</span>
                    <span><i className="legend-node candidate"></i>Candidate</span>
                    <span><i className="legend-node correction"></i>Correction</span>
                    <span><i className="legend-node vocabulary"></i>Vocabulary</span>
                    <span><i className="legend-node voice"></i>Voice sample</span>
                </div>
            }}
        </section>;
}
