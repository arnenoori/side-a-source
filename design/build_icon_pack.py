#!/usr/bin/env python3
"""The app-icon pack, generated from the 1024px full-bleed iOS artwork.

Usage: design/build_icon_pack.py [dir with midnight.png, cobalt.png, ...]

Always writes the in-app art for the phone: each icon the app can wear is resized to 512px into an
`IconArt<Name>.imageset` of apps/ios/SideARemote/Resources/Assets.xcassets, from the 1024px PNG inside its
`AppIcon<Name>.appiconset`. Those sets are what the picker, the lock screen, the welcome screen and the
notifications card draw (an app icon set can't be loaded as an image, and the old 180px previews were soft at
120pt on a 3x screen).

With a source directory it also writes the Mac alternates: the art inset 30px on a 1024 canvas and clipped to a
210px-radius rounded rectangle (the shape design/icon.png has, see build_icon.swift), at 512px, to
Sources/SideA/Resources/AppIcons.
"""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw

IDS = ["midnight", "cobalt", "gold", "glass", "chrome", "crt-pixel"]
INSET, RADIUS, CANVAS, OUT, SS = 30, 210, 1024, 512, 4
# (appiconset, imageset suffix): AppIconOption.art in apps/ios names the imagesets.
IOS_ICONS = [("AppIcon", "Default"), ("AppIconMidnight", "Midnight"), ("AppIconCobalt", "Cobalt"),
             ("AppIconGold", "Gold"), ("AppIconGlass", "Glass"), ("AppIconChrome", "Chrome"),
             ("AppIconCRTPixel", "CRTPixel")]
IOS_ART = 512
ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "apps/ios/SideARemote/Resources/Assets.xcassets"


def ios_art() -> None:
    for iconset, name in IOS_ICONS:
        art = Image.open(CATALOG / f"{iconset}.appiconset/icon.png").convert("RGB")
        dest = CATALOG / f"IconArt{name}.imageset"
        dest.mkdir(parents=True, exist_ok=True)
        art.resize((IOS_ART, IOS_ART), Image.LANCZOS).save(dest / "art.png", optimize=True)
        contents = {"images": [{"idiom": "universal", "filename": "art.png"}], "info": {"author": "xcode", "version": 1}}
        (dest / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def mac_icons(source: Path) -> None:
    dest = ROOT / "Sources/SideA/Resources/AppIcons"
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


def main(source: Path | None) -> None:
    ios_art()
    if source is not None:
        mac_icons(source)


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else None)
