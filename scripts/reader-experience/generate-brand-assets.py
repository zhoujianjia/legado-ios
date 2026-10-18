#!/usr/bin/env python3
"""Generate this fork's geometric bookshelf artwork without upstream images."""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Resources/Assets.xcassets"
BRANDING = ROOT / "Resources/Branding"
PALETTES = {
    "light": ("#F4EFE3", "#164C4B", "#2B7370", "#D27851", "#164C4B"),
    "dark": ("#102F32", "#DDE4D5", "#8DC4B7", "#D99572", "#DDE4D5"),
    "tinted": ("#E9E9E9", "#343434", "#777777", "#A2A2A2", "#343434"),
}


def geometry(palette):
    background, first, second, third, shelf = palette
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<rect width="1024" height="1024" fill="{background}"/>
<rect x="233" y="251" width="142" height="463" rx="22" fill="{first}"/>
<rect x="404" y="313" width="142" height="401" rx="22" fill="{second}"/>
<polygon points="578,305 704,267 812,679 686,714" fill="{third}"/>
<rect x="196" y="740" width="640" height="45" rx="22" fill="{shelf}"/>
<rect x="268" y="303" width="72" height="12" rx="6" fill="{background}"/>
<rect x="439" y="365" width="72" height="12" rx="6" fill="{background}"/>
</svg>\n'''


def render(palette, destination):
    background, first, second, third, shelf = palette
    scale = 3
    image = Image.new("RGB", (1024 * scale, 1024 * scale), background)
    draw = ImageDraw.Draw(image)

    def rect(box, radius, fill):
        draw.rounded_rectangle(tuple(value * scale for value in box), radius=radius * scale, fill=fill)

    rect((233, 251, 375, 714), 22, first)
    rect((404, 313, 546, 714), 22, second)
    draw.polygon([(x * scale, y * scale) for x, y in ((578, 305), (704, 267), (812, 679), (686, 714))], fill=third)
    rect((196, 740, 836, 785), 22, shelf)
    rect((268, 303, 340, 315), 6, background)
    rect((439, 365, 511, 377), 6, background)
    image.resize((1024, 1024), Image.Resampling.LANCZOS).save(destination)


def main():
    BRANDING.mkdir(parents=True, exist_ok=True)
    icon = ASSETS / "AppIcon.appiconset"
    general = ASSETS / "ReaderBrandIcon.imageset"
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
        (directory / "Contents.json").write_text(json.dumps({"images": entries, "info": {"author": "local-bookshelf", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    (BRANDING / "local-bookshelf-icon.svg").write_text(geometry(PALETTES["light"]), encoding="utf-8")
    (BRANDING / "brand-assets.json").write_text(json.dumps({
        "schemaVersion": 1, "productName": "Local Bookshelf", "generatedForThisFork": True,
        "generator": "scripts/reader-experience/generate-brand-assets.py",
        "source": "Resources/Branding/local-bookshelf-icon.svg", "upstreamImagesUsed": False,
        "trademarkClearanceEstablished": False, "outputs": records,
    }, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"generatedAssets": len(records), "upstreamImagesUsed": False}))


if __name__ == "__main__":
    main()
