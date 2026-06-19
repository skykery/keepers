#!/usr/bin/env python3
"""Generate icon.icns for the Keepers .app.

Blue squircle, big white K, centered. Run from the repo root:

    ./venv/bin/python scripts/generate_icon.py

Re-run after tweaking colors or font to regenerate icon.icns.
Requires Pillow (already a dep) and macOS `iconutil`.
"""

import os
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BACKGROUND = (25, 118, 210, 255)   # Material Blue 700
FOREGROUND = (255, 255, 255, 255)  # white
LETTER = "K"


def find_bold_font(size: int) -> ImageFont.FreeTypeFont:
    """Pick a bold sans-serif font that ships with macOS or as a Linux fallback."""
    candidates = [
        ("/System/Library/Fonts/Helvetica.ttc", 1),
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1),
        ("/Library/Fonts/Arial Bold.ttf", 0),
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0),
        ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 0),
    ]
    for path, index in candidates:
        if os.path.exists(path):
            return ImageFont.truetype(path, size=size, index=index)
    raise FileNotFoundError("No bold sans-serif font found on this system")


def render_master(canvas: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # macOS app icons use a rounded-square ("squircle") shape. The corner
    # radius/canvas ratio is approximately 0.2237 in Apple's HIG.
    corner_radius = int(canvas * 0.2237)
    draw.rounded_rectangle(
        (0, 0, canvas - 1, canvas - 1),
        radius=corner_radius,
        fill=BACKGROUND,
    )

    # Size the K so its cap-height is about 65% of the canvas.
    target_height = int(canvas * 0.65)
    font_size = int(canvas * 0.95)  # start large, shrink to fit
    while font_size > 100:
        font = find_bold_font(font_size)
        bbox = draw.textbbox((0, 0), LETTER, font=font, anchor="lt")
        glyph_height = bbox[3] - bbox[1]
        if glyph_height <= target_height:
            break
        font_size -= 20

    # anchor="mm" centers the glyph on the given (x, y) point. The visual
    # center of an uppercase letter sits slightly above the font's metric
    # midline, so nudge down a touch.
    draw.text(
        (canvas // 2, canvas // 2 + int(canvas * 0.03)),
        LETTER,
        fill=FOREGROUND,
        font=font,
        anchor="mm",
    )
    return img


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    master = render_master(1024)

    iconset = repo_root / "icon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()

    # Sizes required for a complete .iconset, per Apple's iconutil docs.
    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for filename, size in sizes:
        master.resize((size, size), Image.LANCZOS).save(iconset / filename)

    icns_path = repo_root / "icon.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
        check=True,
    )
    shutil.rmtree(iconset)
    print(f"Wrote {icns_path}")


if __name__ == "__main__":
    main()
