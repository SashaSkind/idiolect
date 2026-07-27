"""Populate the demo graph through the running app's own API.

Deliberately not a new Jac walker. Every node here is created by the walkers
the app already uses in production — Transcribe, AcceptCorrection,
ManageVocabulary, ManageProfile — so the seeded graph is structurally
identical to one a real user would produce, and there is no second code path
that can drift from the first.

It is also honest data: the utterances are really transcribed. Each demo
sentence is synthesised, degraded, and run through Parakeet, so the Candidate
nodes hold what the recogniser actually returned rather than plausible-looking
strings someone typed. The mishearings in the graph are real mishearings.

Idempotent: profiles are reused by name, and a session that already holds the
expected number of utterances is left alone.

    python3 eval/seed_demo.py            # populate
    python3 eval/seed_demo.py --status   # show what the graph holds
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.environ.get("IDIOLECT_API", "http://localhost:8000")
AUDIO_DIR = os.path.join(ROOT, "data", "seed")

VOICES = ["Daniel", "Karen", "Moira", "Samantha"]

# (sentence the speaker meant, voice index)
CARE_STORY = [
    ("Please remind me to take baclofen", 0),
    ("Can Nadia bring the nebuliser", 1),
    ("My physio is in Wandsworth", 0),
    ("Doctor Okafor changed my gabapentin", 2),
    ("Bryony is bringing the hoist sling", 1),
    ("I need the Gaviscon after lunch", 3),
    ("The catheter needs changing today", 0),
    ("Did I already take my baclofen today", 0),  # the payoff line
]

WORK_STORY = [
    ("The reranker runs in Jaclang", 0),
    ("Jaseci walkers hold the graph", 2),
    ("We are demoing at Fort Mason", 1),
]

#: Extra vocabulary, so the panel looks like months of use rather than one
#: sitting. These are terms a real user accumulates without every one of them
#: having a stored recording.
CARE_EXTRA = [
    "baclofen", "gabapentin", "Gaviscon", "nebuliser", "catheter", "hoist",
    "physiotherapy", "Nadia", "Okafor", "Wandsworth", "Bryony", "commode",
    "Zopiclone", "risperidone", "Siobhan", "ramipril", "spasticity",
    "occupational therapy", "wheelchair clinic", "district nurse",
]
WORK_EXTRA = [
    "Idiolect", "Jaclang", "Jaseci", "byLLM", "reranker", "transcription",
    "Fort Mason", "Parakeet", "walker", "dysarthria",
]


def call(walker: str, payload: dict, timeout: float = 180.0):
    req = urllib.request.Request(
        f"{API}/walker/{walker}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read())
    if not body.get("ok", True):
        raise RuntimeError(f"{walker}: {body.get('error')}")
    # data.result.reports[] is where walkers put their report() values
    result = (body.get("data") or {}).get("result") or {}
    return result.get("reports") or []


def synth(text: str, path: str, voice_idx: int) -> None:
    """Synthesise the sentence, mumbled enough that the recogniser slips."""
    if os.path.exists(path):
        return
    aiff = path + ".aiff"
    subprocess.run(
        ["say", "-r", "212", "-v", VOICES[voice_idx % len(VOICES)], "-o", aiff, text],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", aiff,
         "-af", "volume=0.34,atempo=1.12,lowpass=f=2600,highpass=f=250,aresample=16000",
         "-ar", "16000", "-ac", "1", path],
        check=True, capture_output=True,
    )
    os.remove(aiff)


def ensure_profile(name: str) -> str:
    def find():
        for rep in call("GetProfiles", {}):
            for p in rep.get("profiles", []):
                if p.get("name") == name:
                    return p.get("_jac_id", "")
        return ""
    found = find()
    if found:
        return found
    call("ManageProfile", {"action": "create", "name": name})
    found = find()
    if not found:
        raise RuntimeError(f"could not create profile {name}")
    return found


def seed_story(profile_id: str, label: str, story, extra) -> None:
    os.makedirs(AUDIO_DIR, exist_ok=True)
    snap = call("GetSession", {"profile_id": profile_id})
    existing = len(snap[0].get("recent_utterances", [])) if snap else 0
    if existing >= len(story):
        print(f"  {label}: already has {existing} utterances — skipping")
    else:
        for i, (sentence, voice) in enumerate(story):
            path = os.path.join(AUDIO_DIR, f"{label.lower().replace(' ','_')}_{i}.wav")
            synth(sentence, path, voice)
            rel = os.path.relpath(path, ROOT)
            res = call("Transcribe", {
                "audio_data": "sample:" + rel,
                "mime_type": "audio/wav",
                "profile_id": profile_id,
            })
            row = res[0] if res else {}
            uid = row.get("utterance_id", "")
            heard = (row.get("candidates") or [""])[0]
            if not uid:
                print(f"    ! no utterance id for {sentence!r}")
                continue
            call("AcceptCorrection", {
                "utterance_id": uid,
                "chosen_text": sentence,
                "original_text": heard,
                "method": "picked",
                "profile_id": profile_id,
            })
            mark = "=" if heard.strip().lower() == sentence.lower() else "~"
            print(f"    {mark} heard {heard[:44]!r}")

    for term in extra:
        try:
            call("ManageVocabulary", {
                "action": "add", "term": term, "profile_id": profile_id})
        except Exception:
            pass


def status() -> None:
    profiles = []
    for rep in call("GetProfiles", {}):
        profiles += rep.get("profiles", [])
    print(f"profiles: {len(profiles)}")
    for p in profiles:
        pid = p.get("_jac_id", "")
        snap = call("GetSession", {"profile_id": pid})
        s = snap[0] if snap else {}
        g = (call("GetGraph", {"profile_id": pid}) or [{}])[0]
        from collections import Counter
        kinds = Counter(n.get("kind", "?") for n in g.get("nodes", []))
        print(f"  {p.get('name'):16s} utterances={len(s.get('recent_utterances', [])):3d} "
              f"vocab={len(s.get('vocabulary', [])):3d} "
              f"corrections={s.get('correction_count', '?'):>3} "
              f"training_pairs={s.get('training_pair_count', '?'):>3} "
              f"activities={len(s.get('activities', [])):3d} "
              f"nodes={g.get('node_count', 0):3d} edges={g.get('edge_count', 0):3d}")
        if kinds:
            print("                   " + "  ".join(f"{k}={v}" for k, v in kinds.most_common()))


def main() -> None:
    try:
        call("GetProfiles", {}, timeout=180)
    except Exception as e:
        sys.exit(f"app not reachable at {API} — start it with "
                 f"'.venv/bin/jac start --dev main.jac'  ({e})")

    if "--status" in sys.argv:
        status()
        return

    print("seeding Personal Care...")
    care = ensure_profile("Personal Care")
    seed_story(care, "Personal Care", CARE_STORY, CARE_EXTRA)

    print("seeding Work...")
    work = ensure_profile("Work")
    seed_story(work, "Work", WORK_STORY, WORK_EXTRA)

    print("\nresult:")
    status()


if __name__ == "__main__":
    main()
