#!/usr/bin/env python3
"""Writes Content/templates.json and Content/bookends.json: AURUM's original
video templates and intro/outro presets. All names are in-house.

Run from the repo root:  python3 tools/generate_templates.py
"""
import json
import os

ROOT = os.path.join(os.path.dirname(__file__), "..")


def slot(beats, transition="cut", d=0.25, motion="pushIn", look=None):
    s = {"beats": beats, "transition": {"type": transition} if transition == "cut" else {"type": transition, "duration": d}, "motion": motion}
    if look:
        s["lookID"] = look
    return s


def effect(kind, intensity=0.5, rate=1.0, tier="free", seed=1):
    # Matches AnimatedEffect's Codable shape; the id is fixed so the file is stable.
    return {"id": f"00000000-0000-0000-0000-{seed:012d}", "kind": kind, "intensity": intensity, "rate": rate,
            "start": 0, "seed": seed, "tier": tier}


TEMPLATES = [
    # id, name, tagline, tier, bpm, look, slots, effects, intro, outro
    ("first-look", "First Look", "Five frames, one reveal.", "free", 100, "cinematic.opening-night",
     [slot(4), slot(2), slot(2), slot(2, "dissolve"), slot(6, "dissolve", 0.5, "pullOut")], [], "curtain", None),
    ("atelier-diary", "Atelier Diary", "A slow day in good light.", "free", 84, "film-analog.linen",
     [slot(4, motion="driftLeft"), slot(4, "dissolve", 0.5, "driftRight"), slot(4, "dissolve", 0.5), slot(4, "dissolve", 0.5, "pullOut")],
     [effect("flicker", 0.3, seed=2)], None, "monogram"),
    ("weekend-reel", "Weekend Reel", "Quick cuts for a good weekend.", "free", 120, "riviera.riviera",
     [slot(2), slot(2), slot(1), slot(1), slot(2), slot(2), slot(1), slot(1), slot(4, "zoom", 0.3)], [effect("zoomPulse", 0.4, 2, seed=3)], None, None),
    ("after-hours", "After Hours", "Neon, motion, midnight.", "member", 124, "prism.neon-atelier",
     [slot(2, motion="none"), slot(2, "slide", 0.2), slot(2, "slide", 0.2), slot(2, "slide", 0.2), slot(4, "zoom", 0.3)],
     [effect("glitter", 0.4, tier="member", seed=4), effect("shake", 0.3, 1.5, seed=5)], "spotlight", None),
    ("tape-memories", "Tape Memories", "Home-video warmth.", "free", 96, "retro.rewind",
     [slot(4, motion="none"), slot(4, "dipToBlack", 0.3, "none"), slot(4, "dipToBlack", 0.3, "none")],
     [effect("vhsTracking", 0.5, seed=6)], "tape-start", None),
    ("gilded", "Gilded", "Everything catches the light.", "member", 92, "glow.gilt",
     [slot(4), slot(4, "dissolve", 0.5), slot(4, "dissolve", 0.5), slot(8, "dissolve", 0.75, "pullOut")],
     [effect("lightLeak", 0.6, 0.8, seed=7), effect("glitter", 0.3, tier="member", seed=8)], "curtain", "monogram"),
    ("silver-screen", "Silver Screen", "Black and white, with feeling.", "free", 72, "noir.graphite",
     [slot(4, motion="pushIn"), slot(4, "dissolve", 0.75), slot(4, "dissolve", 0.75), slot(4, "dipToBlack", 0.5)],
     [effect("flicker", 0.5, seed=9)], "title-card", "the-end"),
    ("postcard", "Postcard", "Wish you were here.", "free", 104, "riviera.corniche",
     [slot(4, motion="driftRight"), slot(4, "slide", 0.3, "driftLeft"), slot(4, "slide", 0.3, "driftRight")], [], None, "postmark"),
    ("soft-focus", "Soft Focus", "Hazy, slow, tender.", "free", 76, "haze.velours",
     [slot(6, motion="pullOut"), slot(6, "dissolve", 1.0), slot(6, "dissolve", 1.0)], [effect("lightLeak", 0.4, 0.5, seed=10)], None, None),
    ("countdown", "Countdown", "Twelve beats to midnight.", "member", 128, "seasons.winter-atelier",
     [slot(1, motion="none") for _ in range(8)] + [slot(4, "zoom", 0.3)], [effect("zoomPulse", 0.6, 2.13, seed=11), effect("glitter", 0.5, tier="member", seed=12)], None, "fireworks"),
    ("blue-hour", "Blue Hour", "Between day and night.", "member", 88, "nocturne.velvet-hour",
     [slot(4), slot(4, "dissolve", 0.5), slot(4, "dissolve", 0.5), slot(4, "dissolve", 0.5)], [effect("lightLeak", 0.3, 0.6, seed=13)], None, None),
    ("contact-sheet", "Contact Sheet", "A roll of film, frame by frame.", "free", 112, "film-analog.contact-sheet",
     [slot(1, motion="none") for _ in range(6)] + [slot(2, motion="none")], [effect("flicker", 0.4, seed=14), effect("shake", 0.2, seed=15)], "film-leader", None),
]

BOOKENDS = [
    {"id": "curtain", "name": "Curtain", "kind": "intro", "duration": 1.5, "tier": "free"},
    {"id": "title-card", "name": "Title Card", "kind": "intro", "duration": 2.0, "tier": "free"},
    {"id": "spotlight", "name": "Spotlight", "kind": "intro", "duration": 1.5, "tier": "member"},
    {"id": "tape-start", "name": "Tape Start", "kind": "intro", "duration": 1.2, "tier": "free"},
    {"id": "film-leader", "name": "Film Leader", "kind": "intro", "duration": 2.0, "tier": "member"},
    {"id": "monogram", "name": "Monogram", "kind": "outro", "duration": 1.5, "tier": "free"},
    {"id": "the-end", "name": "Fin", "kind": "outro", "duration": 2.0, "tier": "free"},
    {"id": "postmark", "name": "Postmark", "kind": "outro", "duration": 1.5, "tier": "free"},
    {"id": "fireworks", "name": "Fireworks", "kind": "outro", "duration": 2.0, "tier": "member"},
]


def main():
    out = []
    durations = {b["id"]: b["duration"] for b in BOOKENDS}
    for tid, name, tagline, tier, bpm, look, slots, effects, intro, outro in TEMPLATES:
        t = {"id": tid, "name": name, "tagline": tagline, "tier": tier, "aspect": "story", "slots": slots,
             "bpm": bpm, "lookID": look, "effects": effects}
        if intro:
            t["intro"] = {"presetID": intro, "duration": durations[intro]}
        if outro:
            t["outro"] = {"presetID": outro, "duration": durations[outro]}
        out.append(t)
    os.makedirs(os.path.join(ROOT, "Content"), exist_ok=True)
    with open(os.path.join(ROOT, "Content", "templates.json"), "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    with open(os.path.join(ROOT, "Content", "bookends.json"), "w") as f:
        json.dump(BOOKENDS, f, indent=1)
        f.write("\n")
    print(f"wrote {len(out)} templates, {len(BOOKENDS)} bookends")


if __name__ == "__main__":
    main()
