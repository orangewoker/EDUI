"""Regenerate the iOS AppIcon set from the EDUI branding source."""

import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "branding" / "edui-icon-1024.png"
ICON_SET = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"


def main() -> None:
    source = Image.open(SOURCE).convert("RGB")
    canonical = source.resize((1024, 1024), Image.Resampling.LANCZOS)
    canonical.save(SOURCE, "PNG", optimize=True)
    manifest = json.loads((ICON_SET / "Contents.json").read_text(encoding="utf-8"))
    for entry in manifest["images"]:
        filename = entry.get("filename")
        if not filename:
            continue
        points = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].removesuffix("x"))
        pixels = round(points * scale)
        icon = canonical.resize((pixels, pixels), Image.Resampling.LANCZOS)
        icon.save(ICON_SET / filename, "PNG", optimize=True)


if __name__ == "__main__":
    main()
