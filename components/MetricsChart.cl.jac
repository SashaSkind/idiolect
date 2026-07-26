"""Compact cached evaluation chart."""

sv import from ..walkers { MetricsCurve }


def point_y(value: float) -> float {
    return 12.0 + value * 122.0;
}


def:pub MetricsChart(curve: MetricsCurve | None) -> JsxElement {
    return
        <section className="card metrics-card">
            <div className="section-heading">
                <div>
                    <span className="eyebrow">EVIDENCE</span>
                    <h2>Your words, after each correction</h2>
                </div>
                <span className="metric-badge">WER ↓</span>
            </div>
            {if curve is None {
                <div className="chart-skeleton">Loading cached evaluation…</div>
            } else {
                <div className="chart-wrap">
                    <div className="y-label top">0%</div>
                    <div className="y-label middle">50%</div>
                    <div className="y-label bottom">100%</div>
                    <svg viewBox="0 0 520 155" role="img" aria-label="Word error rate after corrections">
                        <line x1="20" y1="12" x2="510" y2="12" className="grid-line"/>
                        <line x1="20" y1="73" x2="510" y2="73" className="grid-line"/>
                        <line x1="20" y1="134" x2="510" y2="134" className="grid-line"/>
                        <polyline
                            className="chart-line baseline"
                            points={
                                "20," + str(point_y(curve.baseline[0])) +
                                " 90," + str(point_y(curve.baseline[1])) +
                                " 160," + str(point_y(curve.baseline[2])) +
                                " 230," + str(point_y(curve.baseline[3])) +
                                " 300," + str(point_y(curve.baseline[4])) +
                                " 370," + str(point_y(curve.baseline[5])) +
                                " 440," + str(point_y(curve.baseline[6])) +
                                " 510," + str(point_y(curve.baseline[7]))
                            }
                        />
                        <polyline
                            className="chart-line shared"
                            points={
                                "20," + str(point_y(curve.shared_vocabulary[0])) +
                                " 90," + str(point_y(curve.shared_vocabulary[1])) +
                                " 160," + str(point_y(curve.shared_vocabulary[2])) +
                                " 230," + str(point_y(curve.shared_vocabulary[3])) +
                                " 300," + str(point_y(curve.shared_vocabulary[4])) +
                                " 370," + str(point_y(curve.shared_vocabulary[5])) +
                                " 440," + str(point_y(curve.shared_vocabulary[6])) +
                                " 510," + str(point_y(curve.shared_vocabulary[7]))
                            }
                        />
                        <polyline
                            className="chart-line unshared"
                            points={
                                "20," + str(point_y(curve.unshared_vocabulary[0])) +
                                " 90," + str(point_y(curve.unshared_vocabulary[1])) +
                                " 160," + str(point_y(curve.unshared_vocabulary[2])) +
                                " 230," + str(point_y(curve.unshared_vocabulary[3])) +
                                " 300," + str(point_y(curve.unshared_vocabulary[4])) +
                                " 370," + str(point_y(curve.unshared_vocabulary[5])) +
                                " 440," + str(point_y(curve.unshared_vocabulary[6])) +
                                " 510," + str(point_y(curve.unshared_vocabulary[7]))
                            }
                        />
                    </svg>
                    <div className="chart-axis">
                        <span>0</span><span>3</span><span>6</span><span>9</span>
                        <span>11</span><span>14</span><span>17</span><span>20 corrections</span>
                    </div>
                </div>
                <div className="legend">
                    <span><i className="dot shared"></i>Personalised — your words</span>
                    <span><i className="dot unshared"></i>Personalised — all words</span>
                    <span><i className="dot baseline"></i>Recogniser alone</span>
                </div>
                <p className="source-note">{curve.source}</p>
            }}
        </section>;
}
