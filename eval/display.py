"""Build the UI-ready chart file the Jac app loads.  [Track A]

`GetMetrics` in walkers.sv.jac reads ``eval/curve.json`` and expects a flat
shape with exactly eight points per series::

    {"corrections": [int], "baseline": [float],
     "shared_vocabulary": [float], "unshared_vocabulary": [float],
     "source": str}

The measured results live in ``torgo_curve.json`` and ``proxy_curve.json`` in a
richer form. This converts them; it does not recompute anything.

Which numbers go on the chart
-----------------------------
By default, the **proxy benchmark**, because it is the only one where the
effect is real. TORGO is flat — a previously-corrected word is mis-recognised
in under 4% of its held-out utterances, so there is nothing for
personalisation to recover (see FINDINGS.md). Plotting TORGO would draw three
overlapping flat lines and say nothing.

The series are relabelled honestly in ``source`` and via ``series_labels``:
"baseline" is the recogniser alone, "shared_vocabulary" is error on the
speaker's personal terms (R-WER), "unshared_vocabulary" is overall WER. The
field names come from the Jac object and cannot change without touching
Track B's code; the labels tell the viewer what is actually plotted.

Use ``--torgo`` to plot the TORGO curve instead, which is honest and flat.
"""

from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TORGO = os.path.join(HERE, "torgo_curve.json")
PROXY = os.path.join(HERE, "proxy_curve.json")
OUT = os.path.join(HERE, "curve.json")

#: The Jac chart component indexes points 0..7 explicitly.
N_POINTS = 8


def _resample(values: list, n: int = N_POINTS) -> list:
    """Evenly sample `n` items, always keeping first and last."""
    if not values:
        return [0.0] * n
    if len(values) <= n:
        return list(values) + [values[-1]] * (n - len(values))
    step = (len(values) - 1) / (n - 1)
    return [values[round(i * step)] for i in range(n)]


def from_proxy() -> dict:
    d = json.load(open(PROXY))
    pts = d["points"]
    corrections = _resample([p["corrections"] for p in pts])
    rare = _resample([p["rare_wer"] for p in pts])
    overall = _resample([p["wer"] for p in pts])
    base = d["baseline_rare_wer"]
    return {
        "corrections": [int(c) for c in corrections],
        "baseline": [round(base, 4)] * N_POINTS,
        "shared_vocabulary": [round(v, 4) for v in rare],
        "unshared_vocabulary": [round(v, 4) for v in overall],
        "series_labels": {
            "baseline": "Recogniser alone (personal terms)",
            "shared_vocabulary": "Personalised — personal terms (R-WER)",
            "unshared_vocabulary": "Personalised — all words (WER)",
        },
        "source": (
            "Personal-vocabulary benchmark, proxy speaker (synthetic, four "
            "voices; NOT dysarthric speech). Error on the speaker's own terms "
            f"falls {base:.3f} -> {min(rare):.3f} as corrections accumulate. "
            "TORGO is reported separately and is flat by construction — see "
            "eval/FINDINGS.md."
        ),
    }


def from_torgo() -> dict:
    d = json.load(open(TORGO))
    sh, un = d["conditions"]["shared"], d["conditions"]["unshared"]
    corrections = _resample([p["corrections"] for p in sh["points"]])
    return {
        "corrections": [int(c) for c in corrections],
        "baseline": [sh["baseline_wer"]] * N_POINTS,
        "shared_vocabulary": _resample([p["wer"] for p in sh["points"]]),
        "unshared_vocabulary": _resample([p["wer"] for p in un["points"]]),
        "series_labels": {
            "baseline": "Parakeet alone",
            "shared_vocabulary": "Personalised — shared vocabulary",
            "unshared_vocabulary": "Personalised — unshared vocabulary",
        },
        "source": (
            f"TORGO {d.get('speaker', '')}, {d.get('utterances', 0)} sentence "
            "utterances, split by prompt text. Flat: personalisation neither "
            "helps nor harms here, because TORGO's prompts contain almost no "
            "personal vocabulary to recover. See eval/FINDINGS.md."
        ),
    }


def main() -> None:
    use_torgo = "--torgo" in sys.argv
    src = TORGO if use_torgo else PROXY
    if not os.path.exists(src):
        sys.exit(f"missing {src} — run the evaluation first")

    payload = from_torgo() if use_torgo else from_proxy()
    with open(OUT, "w") as f:
        json.dump(payload, f, indent=1)

    print(f"wrote {OUT} from {os.path.basename(src)}")
    print(f"  corrections : {payload['corrections']}")
    print(f"  baseline    : {payload['baseline'][0]}")
    print(f"  series 1    : {payload['shared_vocabulary']}")
    print(f"  series 2    : {payload['unshared_vocabulary']}")


if __name__ == "__main__":
    main()
