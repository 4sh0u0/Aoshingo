# SPDX-License-Identifier: Apache-2.0
"""Regenerates the website icons and the Open Graph image from the app icon.

    python3 site/scripts/make-images.py \
        App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png site/public/assets

Needs Pillow, Inter Display Bold and IPAPGothic (Debian/Ubuntu: fonts-inter, fonts-ipafont-gothic).
Set LATIN_FONT / JAPANESE_FONT to use other font files.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

LATIN_FONT = os.environ.get("LATIN_FONT", "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf")
JAPANESE_FONT = os.environ.get("JAPANESE_FONT", "/usr/share/fonts/opentype/ipafont-gothic/ipagp.ttf")


def rounded(img, radius_ratio=0.2237):
    """iOS-like rounded corners, anti-aliased by drawing the mask at 4x."""
    size = img.size[0]
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * radius_ratio), fill=255
    )
    mask = mask.resize((size, size), Image.LANCZOS)
    rgba = img.convert("RGBA")
    rgba.putalpha(mask)
    return rgba


def main(src, out):
    icon = Image.open(src).convert("RGB")

    # The header logo and favicon get rounded corners; apple-touch-icon must stay square and opaque.
    for name, size, round_corners in [
        ("icon-128.png", 128, True),
        ("favicon-32.png", 32, True),
        ("apple-touch-icon.png", 180, False),
    ]:
        image = icon.resize((size, size), Image.LANCZOS)
        if round_corners:
            image = rounded(image)
        image.save(os.path.join(out, name), optimize=True)

    # Open Graph image, 1200 x 630, on the navy gradient of the app icon.
    width, height = 1200, 630
    og = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(og)
    top, bottom = (11, 31, 69), (19, 64, 107)
    for y in range(height):
        t = y / (height - 1)
        draw.line([(0, y), (width, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    logo = rounded(icon.resize((360, 360), Image.LANCZOS))
    og.paste(logo, (90, (height - 360) // 2), logo)

    title = ImageFont.truetype(LATIN_FONT, 104)
    sub = ImageFont.truetype(JAPANESE_FONT, 40)
    small = ImageFont.truetype(JAPANESE_FONT, 30)
    muted = (201, 214, 234)
    x = 510
    draw.text((x, 140), "Aoshingo", font=title, fill="white")
    draw.text((x, 262), "青信号", font=sub, fill=muted)
    draw.text((x, 350), "歩行者用信号の状態を", font=sub, fill="white")
    draw.text((x, 404), "iPhone で受信して表示", font=sub, fill="white")
    draw.text((x, 486), "高度化PICS 対応・非公式・オープンソース", font=small, fill=muted)
    og.save(os.path.join(out, "og.png"), optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
