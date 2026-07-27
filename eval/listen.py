"""Build a listening page: hear the audio, see what each stage did.  [Track A]

Generates ``listen.html`` at the repo root. Open it in a browser; audio paths
are relative, so keep it where it is.

Two sections:

* **Difficulty ladder** — the same sentence at five degradation levels, so the
  claim "past a threshold the information is gone" is audible rather than
  asserted. You can hear where the recogniser stops mangling the word and
  starts inventing a different one.
* **Benchmark set** — every held-out utterance with its reference, what
  Parakeet heard, and what personalisation produced.
"""

from __future__ import annotations

import html
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from eval.difficulty import LEVELS  # noqa: E402
from eval.proxy import PERSONAL_TERMS, STREAM, TEST, build_audio  # noqa: E402
from eval.torgo import normalize  # noqa: E402
from pipeline import asr, rerank  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "listen.html")

CSS = """
:root{color-scheme:light dark}
body{font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
     max-width:1000px;margin:0 auto;padding:32px 20px 80px}
h1{margin:0 0 4px} .sub{opacity:.65;margin:0 0 28px}
h2{margin:34px 0 8px;font-size:19px}
p.note{opacity:.7;margin:0 0 16px;max-width:70ch}
table{width:100%;border-collapse:collapse;margin-bottom:8px}
td,th{padding:9px 10px;border-bottom:1px solid rgba(128,128,128,.25);
      vertical-align:middle;text-align:left}
th{font-size:12px;text-transform:uppercase;letter-spacing:.05em;opacity:.6}
audio{height:32px;width:190px}
.ref{font-weight:600}
.asr{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;opacity:.85}
.out{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}
.hit{color:#1a7f37;font-weight:600}
.miss{color:#b3261e}
.lvl{font-weight:600;white-space:nowrap}
.tag{display:inline-block;font-size:11px;padding:1px 7px;border-radius:99px;
     background:rgba(128,128,128,.18);margin-left:6px}
@media (prefers-color-scheme:dark){.hit{color:#3fb950}.miss{color:#f85149}}
"""


def mark(text: str, terms: set[str]) -> str:
    """Colour personal terms green when present, so hits are scannable."""
    out = []
    for w in text.split():
        if normalize(w) in terms:
            out.append(f'<span class="hit">{html.escape(w)}</span>')
        else:
            out.append(html.escape(w))
    return " ".join(out)


def main() -> None:
    terms = {normalize(t) for t in PERSONAL_TERMS}
    vocab_counts: dict[str, int] = {}
    for u in STREAM:
        for w in normalize(u).split():
            if w in terms:
                vocab_counts[w] = vocab_counts.get(w, 0) + 1
    vocab = [w for w, _ in sorted(vocab_counts.items(), key=lambda kv: -kv[1])]

    rows_ladder = []
    ref0 = TEST[0]
    print("difficulty ladder...")
    for cfg in LEVELS:
        label = cfg[0]
        p = os.path.join(ROOT, "data", "difficulty", f"{label}_000.wav")
        if not os.path.exists(p):
            continue
        cands = asr.transcribe(p)
        out = rerank.rerank(cands, vocab, [])
        rel = os.path.relpath(p, ROOT)
        rows_ladder.append(
            f"<tr><td class='lvl'>{label}</td>"
            f"<td><audio controls preload='none' src='{rel}'></audio></td>"
            f"<td class='asr'>{html.escape(cands[0])}</td>"
            f"<td class='out'>{mark(out, terms)}</td></tr>"
        )
        print(f"  {label}: {cands[0][:50]!r}")

    print("benchmark set...")
    paths = build_audio()
    rows_test = []
    for t in TEST:
        cands = asr.transcribe(paths[t])
        out = rerank.rerank(cands, vocab, [])
        rel = os.path.relpath(paths[t], ROOT)
        rows_test.append(
            f"<tr><td class='ref'>{mark(t, terms)}</td>"
            f"<td><audio controls preload='none' src='{rel}'></audio></td>"
            f"<td class='asr'>{html.escape(cands[0])}</td>"
            f"<td class='out'>{mark(out, terms)}</td></tr>"
        )

    doc = f"""<!doctype html><meta charset="utf-8">
<title>Idiolect — hear the audio</title><style>{CSS}</style>
<h1>Idiolect — hear what the recogniser hears</h1>
<p class="sub">Proxy speaker: synthesised, acoustically degraded.
<b>Not dysarthric speech.</b> Personal terms are
<span class="hit">highlighted</span> when they survive.</p>

<h2>1. The difficulty ladder <span class="tag">same sentence, five levels</span></h2>
<p class="note">Reference: <b>{html.escape(ref0)}</b>. Listen down the list.
Around the middle the recogniser stops mangling the rare word and starts
confidently substituting a different one — that is where personalisation stops
being able to help, because the evidence is gone rather than merely damaged.</p>
<table><tr><th>level</th><th>audio</th><th>Parakeet heard</th>
<th>after personalisation</th></tr>{''.join(rows_ladder)}</table>

<h2>2. The benchmark set <span class="tag">{len(rows_test)} held-out utterances</span></h2>
<p class="note">Vocabulary learned from {len(STREAM)} corrections
({len(vocab)} personal terms). None of these sentences was ever corrected.</p>
<table><tr><th>reference</th><th>audio</th><th>Parakeet heard</th>
<th>after personalisation</th></tr>{''.join(rows_test)}</table>
"""
    with open(OUT, "w") as f:
        f.write(doc)
    print(f"\nwrote {OUT}")
    print("open it with:  open listen.html")


if __name__ == "__main__":
    main()
