#!/usr/bin/env python3
"""Converts AURUM's sticker SVGs to Android VectorDrawable XML.

Handles exactly the subset the stickers use, and fails loudly on anything
else rather than drawing something different:

- elements: svg, g, path, circle, ellipse, line, polygon, polyline, rect
- paint: fill, stroke, stroke-width, fill-opacity, stroke-opacity, opacity,
  stroke-linecap, stroke-linejoin (inherited from svg and g)
- transform: rotate(a), rotate(a cx cy), translate(x y), translate + rotate
- stroke-dasharray on straight (M/L) paths, expanded into dash segments,
  since VectorDrawable has no dashes

Usage: svg_to_vector.py input.svg > output.xml
"""
from __future__ import annotations

import math
import re
import sys
import xml.etree.ElementTree as ET

SVG_NS = "{http://www.w3.org/2000/svg}"
INHERITED = ["fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "fill-opacity", "stroke-opacity"]
ALLOWED = set(INHERITED) | {"opacity", "transform", "d", "cx", "cy", "r", "rx", "ry", "x", "y", "width", "height",
                            "x1", "y1", "x2", "y2", "points", "stroke-dasharray", "viewBox", "xmlns"}


class Unsupported(Exception):
    pass


def num(v: float) -> str:
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def colour(value: str | None) -> str | None:
    if value is None or value == "none":
        return None
    if re.fullmatch(r"#[0-9a-fA-F]{6}", value):
        return value.upper()
    if re.fullmatch(r"#[0-9a-fA-F]{3}", value):
        return "#" + "".join(c * 2 for c in value[1:]).upper()
    raise Unsupported(f"colour {value!r}")


def parse_transform(t: str) -> dict:
    """Returns group attributes for VectorDrawable (translate applied after rotate)."""
    group: dict[str, float] = {}
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", t):
        values = [float(v) for v in re.split(r"[\s,]+", args.strip()) if v]
        if name == "translate":
            if "rotation" in group:
                raise Unsupported("translate after rotate")
            group["translateX"] = values[0]
            group["translateY"] = values[1] if len(values) > 1 else 0.0
        elif name == "rotate":
            group["rotation"] = values[0]
            if len(values) == 3:
                if "translateX" in group:
                    raise Unsupported("translate then rotate about a point")
                group["pivotX"], group["pivotY"] = values[1], values[2]
        else:
            raise Unsupported(f"transform {name}")
    return group


def ellipse_path(cx: float, cy: float, rx: float, ry: float) -> str:
    return (f"M{num(cx - rx)},{num(cy)} a{num(rx)},{num(ry)} 0 1,0 {num(2 * rx)},0 "
            f"a{num(rx)},{num(ry)} 0 1,0 {num(-2 * rx)},0 Z")


def rect_path(x: float, y: float, w: float, h: float, rx: float, ry: float) -> str:
    if rx <= 0 and ry <= 0:
        return f"M{num(x)},{num(y)} H{num(x + w)} V{num(y + h)} H{num(x)} Z"
    rx = min(rx or ry, w / 2)
    ry = min(ry or rx, h / 2)
    return (f"M{num(x + rx)},{num(y)} H{num(x + w - rx)} A{num(rx)},{num(ry)} 0 0,1 {num(x + w)},{num(y + ry)} "
            f"V{num(y + h - ry)} A{num(rx)},{num(ry)} 0 0,1 {num(x + w - rx)},{num(y + h)} "
            f"H{num(x + rx)} A{num(rx)},{num(ry)} 0 0,1 {num(x)},{num(y + h - ry)} "
            f"V{num(y + ry)} A{num(rx)},{num(ry)} 0 0,1 {num(x + rx)},{num(y)} Z")


def points_path(points: str, close: bool) -> str:
    vals = [float(v) for v in re.split(r"[\s,]+", points.strip()) if v]
    pairs = list(zip(vals[0::2], vals[1::2]))
    d = f"M{num(pairs[0][0])},{num(pairs[0][1])} " + " ".join(f"L{num(x)},{num(y)}" for x, y in pairs[1:])
    return d + (" Z" if close else "")


def polylines(d: str) -> list[list[tuple[float, float]]]:
    """Parses an absolute M/L-only path into polylines; raises otherwise."""
    tokens = re.findall(r"[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?", d)
    lines: list[list[tuple[float, float]]] = []
    cmd = None
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            if t not in "ML":
                raise Unsupported(f"dashes on path command {t}")
            cmd = t
            i += 1
            continue
        x, y = float(tokens[i]), float(tokens[i + 1])
        i += 2
        if cmd == "M":
            lines.append([(x, y)])
            cmd = "L"
        else:
            lines[-1].append((x, y))
    return lines


def dashed(d: str, pattern: list[float]) -> str:
    """Expands a dash pattern along straight polylines into separate segments."""
    out = []
    period = sum(pattern)
    for line in polylines(d):
        offset = 0.0  # position within the pattern, carried across corners like SVG
        for (x0, y0), (x1, y1) in zip(line, line[1:]):
            length = math.hypot(x1 - x0, y1 - y0)
            pos = 0.0
            while pos < length:
                phase = offset % period
                idx, acc = 0, 0.0
                while acc + pattern[idx] <= phase:
                    acc += pattern[idx]
                    idx = (idx + 1) % len(pattern)
                remaining = pattern[idx] - (phase - acc)
                step = min(remaining, length - pos)
                if idx % 2 == 0:  # dash
                    a = pos / length
                    b = (pos + step) / length
                    out.append(f"M{num(x0 + (x1 - x0) * a)},{num(y0 + (y1 - y0) * a)} "
                               f"L{num(x0 + (x1 - x0) * b)},{num(y0 + (y1 - y0) * b)}")
                pos += step
                offset += step
    return " ".join(out)


def element_path(el: ET.Element) -> str:
    tag = el.tag.replace(SVG_NS, "")
    g = lambda k, default=0.0: float(el.get(k, default))  # noqa: E731
    if tag == "path":
        return el.get("d")
    if tag == "circle":
        return ellipse_path(g("cx"), g("cy"), g("r"), g("r"))
    if tag == "ellipse":
        return ellipse_path(g("cx"), g("cy"), g("rx"), g("ry"))
    if tag == "line":
        return f"M{num(g('x1'))},{num(g('y1'))} L{num(g('x2'))},{num(g('y2'))}"
    if tag == "polygon":
        return points_path(el.get("points"), close=True)
    if tag == "polyline":
        return points_path(el.get("points"), close=False)
    if tag == "rect":
        return rect_path(g("x"), g("y"), g("width"), g("height"), g("rx"), g("ry"))
    raise Unsupported(f"element {tag}")


def convert(svg_text: str, note: str = "") -> str:
    root = ET.fromstring(svg_text)
    vb = [float(v) for v in root.get("viewBox", f"0 0 {root.get('width')} {root.get('height')}").split()]
    # The viewport is the SVG's own width and height (iOS draws the image at
    # that size); a different viewBox is fitted inside it, centred ("meet").
    vw = float(root.get("width", vb[2]))
    vh = float(root.get("height", vb[3]))
    lines = ['<?xml version="1.0" encoding="utf-8"?>']
    if note:
        lines.append(f"<!-- {note} -->")
    # Intrinsic size a third of the artwork's, so 360 px art is 120 dp.
    lines.append('<vector xmlns:android="http://schemas.android.com/apk/res/android"')
    lines.append(f'    android:width="{num(vw / 3)}dp"')
    lines.append(f'    android:height="{num(vh / 3)}dp"')
    lines.append(f'    android:viewportWidth="{num(vw)}"')
    lines.append(f'    android:viewportHeight="{num(vh)}">')
    fit_group = vb != [0.0, 0.0, vw, vh]
    if fit_group:
        scale = min(vw / vb[2], vh / vb[3])
        tx = (vw - vb[2] * scale) / 2 - scale * vb[0]
        ty = (vh - vb[3] * scale) / 2 - scale * vb[1]
        lines.append(f'    <group android:scaleX="{num(scale)}" android:scaleY="{num(scale)}" '
                     f'android:translateX="{num(tx)}" android:translateY="{num(ty)}">')

    def walk(el: ET.Element, inherited: dict, depth: int) -> None:
        for attr in el.attrib:
            if attr not in ALLOWED:
                raise Unsupported(f"attribute {attr}")
        style = dict(inherited)
        for k in INHERITED:
            if el.get(k) is not None:
                style[k] = el.get(k)
        indent = "    " * depth
        tag = el.tag.replace(SVG_NS, "")
        group = parse_transform(el.get("transform")) if el.get("transform") else None
        if group is not None:
            attrs = " ".join(f'android:{k}="{num(v)}"' for k, v in group.items())
            lines.append(f"{indent}<group {attrs}>")
            depth += 1
            indent = "    " * depth
        if tag == "g":
            for child in el:
                walk(child, style, depth)
        else:
            d = element_path(el)
            fill = colour(style.get("fill", "#000000"))
            stroke = colour(style.get("stroke"))
            opacity = float(el.get("opacity", 1))
            dash = el.get("stroke-dasharray")
            if dash:
                if fill is not None:
                    raise Unsupported("dashes on a filled shape")
                d = dashed(d, [float(v) for v in re.split(r"[\s,]+", dash.strip())])
            attrs = [f'android:pathData="{d.strip()}"']
            if fill is not None:
                attrs.append(f'android:fillColor="{fill}"')
                alpha = float(style.get("fill-opacity", 1)) * opacity
                if alpha < 1:
                    attrs.append(f'android:fillAlpha="{num(alpha)}"')
            if stroke is not None:
                attrs.append(f'android:strokeColor="{stroke}"')
                attrs.append(f'android:strokeWidth="{num(float(style.get("stroke-width", 1)))}"')
                alpha = float(style.get("stroke-opacity", 1)) * opacity
                if alpha < 1:
                    attrs.append(f'android:strokeAlpha="{num(alpha)}"')
                if style.get("stroke-linecap"):
                    attrs.append(f'android:strokeLineCap="{style["stroke-linecap"]}"')
                if style.get("stroke-linejoin"):
                    attrs.append(f'android:strokeLineJoin="{style["stroke-linejoin"]}"')
            if fill is not None or stroke is not None:
                lines.append(f"{indent}<path\n{indent}    " + f"\n{indent}    ".join(attrs) + " />")
        if group is not None:
            depth -= 1
            lines.append(f"{'    ' * depth}</group>")

    base = {k: root.get(k) for k in INHERITED if root.get(k) is not None}
    for child in root:
        walk(child, base, 2 if fit_group else 1)
    if fit_group:
        lines.append("    </group>")
    lines.append("</vector>")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as f:
        sys.stdout.write(convert(f.read()))
