#!/usr/bin/env python3
"""Generates AURUM's in-house sticker artwork as SVG image sets.

Every sticker is drawn here from simple geometry, so the artwork is original
and needs no licence. Output: App/Assets.xcassets/sticker.<id>.imageset/.
Xcode keeps the vector data, so stickers stay sharp at any export size.

Run from the repo root:  python3 tools/generate_stickers.py
"""
import json
import math
import os

GOLD = "#C9A86A"
IVORY = "#F4EFE6"
DEEP = "#8C6B3A"
W = 360


def svg(body, height=W):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" '
            f'viewBox="0 0 {W} {height}" fill="none" stroke-linecap="round" stroke-linejoin="round">'
            f'{body}</svg>\n')


def star(cx, cy, r_out, r_in, points=4, rot=-90):
    pts = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(rot + i * 180 / points)
        pts.append(f"{cx + r * math.cos(a):.1f},{cy + r * math.sin(a):.1f}")
    return " ".join(pts)


def sparkle():
    return svg(
        f'<polygon points="{star(180, 180, 150, 26)}" fill="{GOLD}"/>'
        f'<polygon points="{star(285, 80, 42, 8)}" fill="{IVORY}"/>'
        f'<polygon points="{star(80, 285, 30, 6)}" fill="{IVORY}"/>'
        f'<circle cx="290" cy="270" r="7" fill="{GOLD}"/>')


def laurel():
    """Two branches curving up from the bottom and open at the top, like a victor's wreath."""
    body = ""
    for side in (-1, 1):
        angles = [100 + 22 * i for i in range(7)] if side < 0 else [80 - 22 * i for i in range(7)]
        pts = [(180 + 130 * math.cos(math.radians(a)), 190 + 130 * math.sin(math.radians(a))) for a in angles]
        body += f'<path d="M {" L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)}" stroke="{GOLD}" stroke-width="4"/>'
        for (x, y), deg in zip(pts, angles):
            # A pair of leaves at each node: one outside the ring, one inside, both leaning up the stem.
            lean = -side * 40
            for offset, scale in ((0, 1.0), (180, 0.8)):
                a = math.radians(deg + offset + lean)
                lx, ly = x + 20 * scale * math.cos(a), y + 20 * scale * math.sin(a)
                body += (f'<ellipse cx="{lx:.1f}" cy="{ly:.1f}" rx="{9 * scale:.1f}" ry="{22 * scale:.1f}" '
                         f'transform="rotate({deg + offset + lean + 90:.1f} {lx:.1f} {ly:.1f})" fill="{GOLD}"/>')
    return svg(body)


def bow():
    return svg(
        f'<path d="M180 175 C 120 100, 40 110, 55 170 C 65 220, 130 215, 180 175 Z" stroke="{GOLD}" stroke-width="8" fill="{GOLD}" fill-opacity="0.18"/>'
        f'<path d="M180 175 C 240 100, 320 110, 305 170 C 295 220, 230 215, 180 175 Z" stroke="{GOLD}" stroke-width="8" fill="{GOLD}" fill-opacity="0.18"/>'
        f'<path d="M172 185 L 120 320 M188 185 L 240 320" stroke="{GOLD}" stroke-width="8"/>'
        f'<ellipse cx="180" cy="178" rx="20" ry="24" fill="{GOLD}"/>')


def heart_line():
    return svg(
        f'<path d="M180 315 C 60 230, 30 160, 70 100 C 110 45, 170 70, 180 120 C 190 70, 250 45, 290 100 C 330 160, 300 230, 180 315 Z" stroke="{IVORY}" stroke-width="7"/>'
        f'<path d="M180 280 C 95 220, 75 170, 100 128" stroke="{GOLD}" stroke-width="3"/>')


def pearls():
    beads = []
    for i in range(15):
        t = i / 14
        x = 30 + 300 * t
        y = 110 + 150 * math.sin(math.pi * t)
        beads.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="17" fill="{IVORY}" stroke="{GOLD}" stroke-width="2"/>'
                     f'<circle cx="{x - 5:.1f}" cy="{y - 6:.1f}" r="5" fill="#FFFFFF" opacity="0.8"/>')
    return svg("".join(beads))


def monogram():
    return svg(
        f'<circle cx="180" cy="180" r="150" stroke="{GOLD}" stroke-width="4"/>'
        f'<circle cx="180" cy="180" r="136" stroke="{GOLD}" stroke-width="1.5"/>'
        f'<path d="M115 255 L 180 95 L 245 255 M140 195 L 220 195" stroke="{GOLD}" stroke-width="10"/>'
        f'<path d="M100 255 H 135 M225 255 H 260" stroke="{GOLD}" stroke-width="6"/>')


def oval_frame():
    h = 450
    return svg(
        f'<ellipse cx="180" cy="225" rx="160" ry="205" stroke="{GOLD}" stroke-width="10"/>'
        f'<ellipse cx="180" cy="225" rx="145" ry="190" stroke="{IVORY}" stroke-width="2"/>'
        f'<polygon points="{star(180, 22, 18, 5)}" fill="{GOLD}"/>'
        f'<polygon points="{star(180, 428, 18, 5)}" fill="{GOLD}"/>', h)


def gallery_frame():
    h = 450
    corners = "".join(
        f'<rect x="{x - 14}" y="{y - 14}" width="28" height="28" transform="rotate(45 {x} {y})" fill="{GOLD}"/>'
        for x, y in ((20, 20), (340, 20), (20, 430), (340, 430)))
    return svg(
        f'<rect x="20" y="20" width="320" height="410" stroke="{GOLD}" stroke-width="16"/>'
        f'<rect x="42" y="42" width="276" height="366" stroke="{DEEP}" stroke-width="4"/>'
        f'<rect x="52" y="52" width="256" height="346" stroke="{IVORY}" stroke-width="1.5"/>' + corners, h)


def crescent():
    return svg(
        f'<path d="M230 45 A 140 140 0 1 0 230 315 A 110 110 0 1 1 230 45 Z" fill="{GOLD}"/>'
        f'<polygon points="{star(265, 140, 26, 6)}" fill="{IVORY}"/>'
        f'<circle cx="300" cy="215" r="5" fill="{IVORY}"/>')


def sunburst():
    rays = []
    for i in range(24):
        a = math.radians(i * 15)
        r1, r2 = 70, (165 if i % 2 == 0 else 125)
        rays.append(f'<line x1="{180 + r1 * math.cos(a):.1f}" y1="{180 + r1 * math.sin(a):.1f}" '
                    f'x2="{180 + r2 * math.cos(a):.1f}" y2="{180 + r2 * math.sin(a):.1f}" stroke="{GOLD}" stroke-width="5"/>')
    return svg("".join(rays) + f'<circle cx="180" cy="180" r="52" fill="{GOLD}"/><circle cx="180" cy="180" r="40" stroke="{IVORY}" stroke-width="2"/>')


def constellation():
    pts = [(50, 260), (110, 190), (175, 215), (230, 130), (310, 90), (280, 230)]
    lines = " ".join(f"L {x} {y}" for x, y in pts[1:5])
    body = f'<path d="M {pts[0][0]} {pts[0][1]} {lines}" stroke="{IVORY}" stroke-width="2" stroke-dasharray="2 8"/>'
    body += f'<path d="M 175 215 L 280 230" stroke="{IVORY}" stroke-width="2" stroke-dasharray="2 8"/>'
    for i, (x, y) in enumerate(pts):
        body += f'<polygon points="{star(x, y, 22 if i % 2 else 15, 4)}" fill="{GOLD}"/>'
    return svg(body)


def envelope():
    h = 260
    return svg(
        f'<rect x="20" y="20" width="320" height="220" rx="10" fill="{IVORY}" stroke="{GOLD}" stroke-width="5"/>'
        f'<path d="M24 28 L 180 145 L 336 28" stroke="{GOLD}" stroke-width="5"/>'
        f'<circle cx="180" cy="145" r="28" fill="{DEEP}"/><circle cx="180" cy="145" r="19" stroke="{GOLD}" stroke-width="2"/>', h)


def wax_seal():
    blob = []
    for i in range(36):
        a = math.radians(i * 10)
        r = 150 + (9 if i % 3 == 0 else -4)
        blob.append(f"{180 + r * math.cos(a):.1f},{180 + r * math.sin(a):.1f}")
    return svg(
        f'<polygon points="{" ".join(blob)}" fill="#7A1F2B"/>'
        f'<circle cx="180" cy="180" r="105" stroke="{GOLD}" stroke-width="5"/>'
        f'<polygon points="{star(180, 180, 70, 28, points=5)}" fill="{GOLD}"/>')


def snowflake():
    arms = []
    for i in range(6):
        a = i * 60
        arms.append(
            f'<g transform="rotate({a} 180 180)">'
            f'<line x1="180" y1="180" x2="180" y2="30" stroke="{IVORY}" stroke-width="9"/>'
            f'<path d="M180 80 L 145 50 M180 80 L 215 50 M180 130 L 150 105 M180 130 L 210 105" stroke="{IVORY}" stroke-width="7"/>'
            f'</g>')
    return svg("".join(arms) + f'<circle cx="180" cy="180" r="16" fill="{GOLD}"/>')


def holly():
    """Two leaves and three berries, scaled up to fill the canvas."""
    leaf = "M0 0 C 30 -20, 60 -10, 90 -35 C 85 -10, 105 5, 120 0 C 105 -5, 85 10, 90 35 C 60 10, 30 20, 0 0 Z"
    return svg(
        f'<path d="{leaf}" transform="translate(180 190) rotate(-150)" fill="#2F4A3A" stroke="{GOLD}" stroke-width="3"/>'
        f'<path d="{leaf}" transform="translate(180 190) rotate(-30)" fill="#2F4A3A" stroke="{GOLD}" stroke-width="3"/>'
        f'<circle cx="165" cy="205" r="22" fill="#8C2F39"/><circle cx="198" cy="210" r="22" fill="#8C2F39"/><circle cx="182" cy="180" r="22" fill="#8C2F39"/>'
        f'<circle cx="176" cy="173" r="5" fill="#FFFFFF" opacity="0.6"/>'
    ).replace('viewBox="0 0 360 360"', 'viewBox="70 110 220 160"')


STICKERS = {
    "sparkle": sparkle, "laurel": laurel, "bow": bow, "heart-line": heart_line,
    "pearls": pearls, "monogram": monogram, "oval-frame": oval_frame,
    "gallery-frame": gallery_frame, "crescent": crescent, "sunburst": sunburst,
    "constellation": constellation, "envelope": envelope, "wax-seal": wax_seal,
    "snowflake": snowflake, "holly": holly,
}


def main():
    root = os.path.join(os.path.dirname(__file__), "..", "App", "Assets.xcassets")
    for sid, draw in STICKERS.items():
        d = os.path.join(root, f"sticker.{sid}.imageset")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"{sid}.svg"), "w") as f:
            f.write(draw())
        contents = {
            "images": [{"filename": f"{sid}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True},
        }
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2)
            f.write("\n")
    print(f"wrote {len(STICKERS)} stickers")


if __name__ == "__main__":
    main()
