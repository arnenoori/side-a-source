#!/usr/bin/env python3
"""Mac app-icon alternates from the 1024px full-bleed iOS artwork.

Usage: design/build_icon_pack.py <dir with midnight.png, cobalt.png, ...>

Gives each one the shape design/icon.png has (see build_icon.swift): the art inset 30px on a 1024 canvas
and clipped to a 210px-radius rounded rectangle, then written at 512px to Sources/SideA/Resources/AppIcons.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

IDS = ["midnight", "cobalt", "gold", "glass", "chrome", "crt-pixel"]
INSET, RADIUS, CANVAS, OUT, SS = 30, 210, 1024, 512, 4

def main(source: Path) -> None:
    root = Path(__file__).resolve().parent.parent
    dest = root / "Sources/SideA/Resources/AppIcons"
    dest.mkdir(parents=True, exist_ok=True)
    big = CANVAS * SS
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [INSET * SS, INSET * SS, big - INSET * SS - 1, big - INSET * SS - 1], radius=RADIUS * SS, fill=255)
    mask = mask.resize((CANVAS, CANVAS), Image.LANCZOS)
    for icon in IDS:
        art = Image.open(source / f"{icon}.png").convert("RGB").resize((CANVAS - 2 * INSET,) * 2, Image.LANCZOS)
        out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        out.paste(art, (INSET, INSET))
        out.putalpha(mask)
        out.resize((OUT, OUT), Image.LANCZOS).save(dest / f"{icon}.png", optimize=True)

if __name__ == "__main__":
    main(Path(sys.argv[1]))
