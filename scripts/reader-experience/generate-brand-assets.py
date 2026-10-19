#!/usr/bin/env python3
"""Render the fork's original open-book vector artwork into its asset catalogs."""
from pathlib import Path
import hashlib
import json
import math
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Resources/Assets.xcassets"
BRANDING = ROOT / "Resources/Branding"
PALETTES = {
    "light": ("#F4EFE3", "#164C4B", "#FFFCF4", "#E3ECE5", "#D27851"),
    "dark": ("#102F32", "#8DC4B7", "#F2EFDF", "#DDE4D5", "#D99572"),
    "tinted": ("#E9E9E9", "#343434", "#FAFAFA", "#D6D6D6", "#777777"),
}


def blend(first, second, weight):
    channels = tuple(round(int(first[i:i + 2], 16) * weight
                           + int(second[i:i + 2], 16) * (1 - weight)) for i in (1, 3, 5))
    return "#" + "".join(f"{channel:02X}" for channel in channels)


def artwork(palette):
    """One set of cubic paths supplies both the editable SVG and PNG variants."""
    _, cover, left, right, bookmark = palette
    lines = blend(cover, right, 0.42)
    paths = [
        # Cover below the two separately curved pages, with a visible lower spine.
        ([('M', 170, 310), ('C', 326, 269, 430, 296, 512, 366),
          ('C', 594, 296, 698, 269, 854, 310), ('L', 854, 734),
          ('C', 716, 696, 612, 714, 512, 776),
          ('C', 412, 714, 308, 696, 170, 734), ('Z',)], cover, None, 0),
        ([('M', 204, 278), ('C', 320, 258, 434, 286, 512, 350),
          ('L', 512, 740), ('C', 414, 677, 305, 669, 204, 700), ('Z',)], left, cover, 10),
        ([('M', 512, 350), ('C', 590, 286, 704, 258, 820, 278),
          ('L', 820, 700), ('C', 719, 669, 610, 677, 512, 740), ('Z',)], right, cover, 10),
    ]
    for offset in (0, 78, 156):
        paths.extend([
            ([('M', 254, 384 + offset),
              ('C', 328, 376 + offset, 405, 395 + offset, 462, 431 + offset)], None, lines, 14),
            ([('M', 562, 431 + offset),
              ('C', 619, 395 + offset, 696, 376 + offset, 770, 384 + offset)], None, lines, 14),
        ])
    paths.append(([('M', 650, 296), ('C', 672, 289, 691, 285, 712, 282),
                   ('L', 712, 454), ('L', 681, 433), ('L', 650, 454), ('Z',)], bookmark, None, 0))
    return paths


def geometry(palette):
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">',
             f'<rect width="1024" height="1024" fill="{palette[0]}"/>']
    for commands, fill, stroke, width in artwork(palette):
        path = " ".join(command[0] + " ".join(f"{value:g}" for value in command[1:]) for command in commands)
        join = "miter" if commands[-1][0] == 'Z' else "round"
        parts.append(f'<path d="{path}" fill="{fill or "none"}" stroke="{stroke or "none"}" '
                     f'stroke-width="{width}" stroke-linecap="round" stroke-linejoin="{join}"/>')
    return "\n".join(parts) + "\n</svg>\n"


def flatten(commands):
    points = []
    for command in commands:
        kind, *values = command
        if kind in ('M', 'L'):
            points.append(tuple(values))
        elif kind == 'C':
            x0, y0 = points[-1]
            x1, y1, x2, y2, x3, y3 = values
            for step in range(1, 65):
                t = step / 64
                s = 1 - t
                points.append((s ** 3 * x0 + 3 * s * s * t * x1 + 3 * s * t * t * x2 + t ** 3 * x3,
                               s ** 3 * y0 + 3 * s * s * t * y1 + 3 * s * t * t * y2 + t ** 3 * y3))
        elif kind == 'Z':
            points.append(points[0])
        else:
            raise ValueError("Unsupported vector command: " + kind)
    return points


def stroke_path(draw, points, color, width):
    """Join a sampled curve with continuous filled edges and round caps."""
    closed = points[0] == points[-1]
    nodes = points[:-1] if closed else points
    left, right = [], []
    radius = width / 2

    def direction(first, second):
        dx, dy = second[0] - first[0], second[1] - first[1]
        length = math.hypot(dx, dy)
        return dx / length, dy / length

    for i, (x, y) in enumerate(nodes):
        incoming = direction(nodes[i - 1], nodes[i]) if closed or i else direction(nodes[0], nodes[1])
        outgoing = direction(nodes[i], nodes[(i + 1) % len(nodes)]) if closed or i + 1 < len(nodes) else incoming
        divisor = 1 + incoming[0] * outgoing[0] + incoming[1] * outgoing[1]
        if divisor <= 0:
            raise ValueError("Reversing stroke segment")
        nx = -(incoming[1] + outgoing[1]) * radius / divisor
        ny = (incoming[0] + outgoing[0]) * radius / divisor
        left.append((x + nx, y + ny))
        right.append((x - nx, y - ny))
    for i in range(len(nodes) if closed else len(nodes) - 1):
        after = (i + 1) % len(nodes)
        draw.polygon((left[i], left[after], right[after], right[i]), fill=color)
    if not closed:
        for x, y in (nodes[0], nodes[-1]):
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)


def render(palette, destination):
    scale = 3
    image = Image.new("RGB", (1024 * scale, 1024 * scale), palette[0])
    draw = ImageDraw.Draw(image)
    for commands, fill, stroke, width in artwork(palette):
        points = [(x * scale, y * scale) for x, y in flatten(commands)]
        if fill:
            draw.polygon(points, fill=fill)
        if stroke:
            stroke_path(draw, points, stroke, width * scale)
    image.resize((1024, 1024), Image.Resampling.LANCZOS).save(destination)


def main():
    BRANDING.mkdir(parents=True, exist_ok=True)
    icon = ASSETS / "AppIcon.appiconset"
    general = ASSETS / "ReaderBrandIcon.imageset"
    icon.mkdir(parents=True, exist_ok=True)
    general.mkdir(parents=True, exist_ok=True)
    records, icons, images = [], [], []
    for mode, palette in PALETTES.items():
        name = f"LocalBookshelf-{mode}.png"
        render(palette, icon / name)
        record = {"filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if mode != "light":
            record["appearances"] = [{"appearance": "luminosity", "value": mode}]
        icons.append(record)
        if mode in ("light", "dark"):
            (general / name).write_bytes((icon / name).read_bytes())
            item = {"filename": name, "idiom": "universal", "scale": "1x"}
            if mode == "dark":
                item["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            images.append(item)
        data = (icon / name).read_bytes()
        records.append({"file": str((icon / name).relative_to(ROOT)).replace("\\", "/"),
                        "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    for directory, entries in ((icon, icons), (general, images)):
        contents = directory / "Contents.json"
        metadata = {"images": entries, "info": {"author": "local-bookshelf", "version": 1}}
        if not contents.exists() or json.loads(contents.read_text(encoding="utf-8")) != metadata:
            contents.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8", newline="\n")
    (BRANDING / "local-bookshelf-icon.svg").write_text(geometry(PALETTES["light"]), encoding="utf-8", newline="\n")
    (BRANDING / "brand-assets.json").write_text(json.dumps({
        "schemaVersion": 1, "productName": "阅读", "iconMotif": "open-book", "generatedForThisFork": True,
        "generator": "scripts/reader-experience/generate-brand-assets.py",
        "source": "Resources/Branding/local-bookshelf-icon.svg", "upstreamImagesUsed": False,
        "trademarkClearanceEstablished": False, "outputs": records,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({"generatedAssets": len(records), "upstreamImagesUsed": False}))


if __name__ == "__main__":
    main()
