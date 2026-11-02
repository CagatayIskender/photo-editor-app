#!/usr/bin/env python3
"""Builds Looks/catalog.json, the AURUM look catalogue.

Each collection is a parametric family: a base recipe plus ten named
variations. Values are deterministic (no randomness), so running the script
twice gives identical output and CI can check the committed file is current.

    python3 tools/generate_catalog.py          # write the catalogue
    python3 tools/generate_catalog.py --check  # fail if the file is stale

Names are original. The deny-list below stops competitor or camera-brand
names from slipping in; AurumCore's tests enforce the same list.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Looks" / "catalog.json"

DENY = [
    "vsco", "huji", "dazz", "lightroom", "snapseed", "picsart", "prequel", "facetune",
    "kodak", "fuji", "polaroid", "ilford", "agfa", "instagram", "tiktok", "lomo",
    "portra", "ektar", "velvia", "tri-x", "hp5", "cinestill", "hasselblad", "leica",
]

FREE_PER_COLLECTION = 3

# id, display name, tagline, base params, swatch pair, tags, ten look names
COLLECTIONS = [
    ("film-analog", "Film & Analog", "Grain, warmth and the honesty of a single frame.",
     dict(contrast=-0.06, saturation=-0.08, warmth=0.18, fade=0.16, grain=0.28, vignette=0.12,
          shadowsTint=[1.02, 1.0, 0.94], highlightsTint=[1.04, 1.0, 0.92]),
     ["#E9C9A0", "#7A4E30"], ["film", "analog", "grain", "warm", "35mm"],
     ["Linen", "Matinee", "Contact Sheet", "Darkroom", "Sunday Roll", "Postcard",
      "Half Frame", "Keepsake", "Amber Leader", "Box Camera"]),
    ("cinematic", "Cinematic", "Teal shadows, amber skin, a story in every still.",
     dict(contrast=0.14, saturation=0.04, warmth=0.06, highlights=-0.12, shadows=0.08, vignette=0.2,
          shadowsTint=[0.9, 1.0, 1.08], highlightsTint=[1.08, 1.0, 0.9]),
     ["#E6B884", "#1F4A55"], ["cinematic", "teal", "orange", "movie", "dramatic"],
     ["Opening Night", "Last Reel", "Anamorphic", "Golden Hour Set", "Night Shoot", "Director's Chair",
      "Wide Release", "Score", "Location", "Dailies"]),
    ("noir", "Noir", "Black and white, with a little velvet in the shadows.",
     dict(contrast=0.22, saturation=-1.0, grain=0.18, vignette=0.22, monochrome=True),
     ["#E6E2DC", "#202022"], ["bw", "monochrome", "black and white", "noir", "classic"],
     ["Graphite", "Charcoal", "Silver Gelatin", "Ink", "Salon Noir", "Pearl",
      "Smoke", "Onyx", "Chalk", "Midnight Print"]),
    ("haze", "Soft Haze", "Low contrast, lifted blacks, a slow afternoon.",
     dict(contrast=-0.2, saturation=-0.12, fade=0.28, bloom=0.22, exposure=0.06,
          highlightsTint=[1.03, 0.99, 1.02]),
     ["#F2DCE0", "#A88A9A"], ["dreamy", "haze", "soft", "pastel", "airy"],
     ["Velours", "Chiffon", "Blush Veil", "Morning Room", "Linen Sheets", "Petal",
      "Cloud Nine", "Powder", "Organza", "Daydream"]),
    ("glow", "Glow & Bloom", "Light that lingers on skin and silk.",
     dict(contrast=0.02, saturation=0.06, warmth=0.12, bloom=0.42, highlights=-0.06, exposure=0.04),
     ["#F2D79A", "#8A5A2A"], ["glow", "bloom", "golden", "radiant", "warm", "sparkle"],
     ["Gilt", "Candlelight", "Halo", "Honey", "Vermeil", "Lantern",
      "Afterglow", "Champagne", "Aurora Gold", "Lumière"]),
    ("retro", "Retro Tape", "Nineties home video, kept in a velvet box.",
     dict(contrast=0.08, saturation=0.14, tint=0.06, fade=0.12, grain=0.34, grainSize=1.6, lightLeak=0.18,
          shadowsTint=[0.96, 1.0, 1.06]),
     ["#D98A9A", "#2E2A5A"], ["90s", "retro", "vhs", "camcorder", "tape"],
     ["Rewind", "Tracking", "Mixtape", "Saturday Tape", "Arcade", "Prom Night",
      "Pager", "Boombox", "Static", "Freeze Frame"]),
    ("riviera", "Riviera", "Sun on stone, salt in the air.",
     dict(contrast=0.1, saturation=0.22, vibrance=0.18, warmth=0.1, exposure=0.06,
          shadowsTint=[0.94, 1.0, 1.06]),
     ["#F2C98A", "#2E6A7A"], ["summer", "sunny", "travel", "vivid", "warm"],
     ["Riviera", "Corniche", "Lido", "Limoncello", "Cabana", "Azure Steps",
      "Terrace", "Siesta", "Harbour", "Marina Blue"]),
    ("nocturne", "Nocturne", "Deep shadows and cool, quiet light.",
     dict(contrast=0.24, saturation=-0.2, exposure=-0.12, warmth=-0.16, vignette=0.32,
          shadowsTint=[0.9, 0.96, 1.1]),
     ["#9AA8B6", "#1C232B"], ["moody", "dark", "cool", "night", "shadow"],
     ["Nocturne", "Velvet Hour", "Blue Salon", "Opera", "Slate", "Moonlit",
      "After Hours", "Storm", "Indigo", "Last Call"]),
    ("prism", "Prism & Neon", "City light, refracted.",
     dict(contrast=0.18, saturation=0.3, vibrance=0.2, tint=0.12, bloom=0.2,
          shadowsTint=[0.96, 0.9, 1.12], highlightsTint=[1.06, 0.96, 1.04]),
     ["#D9B8F0", "#2A0E3A"], ["neon", "night city", "prism", "rainbow", "vivid"],
     ["Prism", "Spectre", "Neon Atelier", "Refraction", "Electric Rose", "Afterparty",
      "Chromatic", "Signal", "Ultraviolet", "Glasshouse"]),
    ("seasons", "Seasons", "Collections for the calendar's best days.",
     dict(contrast=0.06, saturation=0.04, fade=0.08, bloom=0.12),
     ["#C8D2DA", "#6A2A2A"], ["seasonal", "holiday", "winter", "autumn", "festive"],
     ["Winter Atelier", "First Snow", "Frost", "Mulled", "Evergreen", "Valentine",
      "Harvest", "Ember", "Masquerade", "New Year"]),
]

# Ten variation offsets applied to the base params; index i gives look i.
VARIATIONS = [
    {},
    dict(warmth=0.08, fade=0.04),
    dict(contrast=0.08, saturation=-0.06),
    dict(exposure=-0.06, vignette=0.08),
    dict(warmth=-0.1, tint=-0.04),
    dict(saturation=0.1, vibrance=0.08),
    dict(fade=0.1, contrast=-0.08),
    dict(grain=0.12, lightLeak=0.12),
    dict(bloom=0.14, exposure=0.04),
    dict(contrast=0.12, highlights=-0.1, shadows=0.06),
]

RANGES = {
    "fade": (0, 1), "grain": (0, 1), "vignette": (0, 1), "lightLeak": (0, 1), "bloom": (0, 1),
    "grainSize": (0.5, 2),
}

# Seasonal looks get their own tints so a Valentine look reads as one.
SEASON_TINTS = {
    "Winter Atelier": dict(warmth=-0.2, shadowsTint=[0.92, 0.97, 1.08]),
    "First Snow": dict(warmth=-0.14, exposure=0.1, fade=0.12),
    "Frost": dict(warmth=-0.26, saturation=-0.14),
    "Mulled": dict(warmth=0.24, tint=0.06, saturation=0.08),
    "Evergreen": dict(tint=-0.12, saturation=0.06, shadowsTint=[0.94, 1.04, 0.98]),
    "Valentine": dict(tint=0.18, warmth=0.08, bloom=0.2, highlightsTint=[1.08, 0.96, 1.0]),
    "Harvest": dict(warmth=0.2, saturation=0.1),
    "Ember": dict(warmth=0.3, contrast=0.1, vignette=0.2),
    "Masquerade": dict(contrast=0.2, saturation=-0.1, tint=0.1, vignette=0.3),
    "New Year": dict(bloom=0.3, saturation=0.12, contrast=0.1),
}


def slug(name: str) -> str:
    out = "".join(c.lower() if c.isalnum() else "-" for c in name)
    while "--" in out:
        out = out.replace("--", "-")
    return out.strip("-")


def combine(base: dict, *offsets: dict) -> dict:
    params = dict(base)
    for off in offsets:
        for key, value in off.items():
            if isinstance(value, list) or isinstance(value, bool):
                params[key] = value
            else:
                params[key] = params.get(key, 0) + value
    for key, value in list(params.items()):
        if isinstance(value, (list, bool)):
            continue
        lo, hi = RANGES.get(key, (-1, 1))
        params[key] = round(min(max(value, lo), hi), 3)
    return params


def build() -> dict:
    collections, looks = [], []
    for cid, cname, tagline, base, swatch, tags, names in COLLECTIONS:
        assert len(names) == 10, cid
        collections.append({"id": cid, "name": cname, "tagline": tagline})
        for i, name in enumerate(names):
            lowered = name.lower()
            for bad in DENY:
                assert bad not in lowered, f"denied term {bad!r} in {name!r}"
            params = combine(base, VARIATIONS[i], SEASON_TINTS.get(name, {}))
            looks.append({
                "id": f"{cid}.{slug(name)}",
                "name": name,
                "collection": cid,
                "tier": "free" if i < FREE_PER_COLLECTION else "member",
                "tags": tags,
                "lut": None,
                "params": params,
                "swatch": swatch,
            })
    return {"version": 1, "collections": collections, "looks": looks}


def main() -> int:
    text = json.dumps(build(), indent=2, sort_keys=True) + "\n"
    if "--check" in sys.argv:
        current = OUT.read_text() if OUT.exists() else ""
        if current != text:
            print("Looks/catalog.json is stale. Run tools/generate_catalog.py.")
            return 1
        print("Looks/catalog.json is up to date.")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    data = json.loads(text)
    free = sum(1 for look in data["looks"] if look["tier"] == "free")
    print(f"Wrote {len(data['looks'])} looks in {len(data['collections'])} collections ({free} free).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
