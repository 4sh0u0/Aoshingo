# SPDX-License-Identifier: Apache-2.0
"""Regenerates the website icons and the Open Graph image from the app icon.

    python3 site/scripts/make-images.py \
        App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png site/public/assets

Needs Pillow, Inter Display Bold and IPAPGothic (Debian/Ubuntu: fonts-inter, fonts-ipafont-gothic).
Set LATIN_FONT / JAPANESE_FONT to use other font files.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

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

    draw_og(icon).save(os.path.join(out, "og.png"), optimize=True)


# Pictograms of site/public/index.html (#i-walk, #i-stand), as strokes on a 48 x 48 grid.
WALK = {
    "head": (27, 8),
    "strokes": [
        [(25, 16), (21, 29)],
        [(24, 17), (30, 23), (35, 24)],
        [(24, 17), (18, 22), (16, 28)],
        [(21, 29), (28, 35), (29, 44)],
        [(21, 29), (17, 36), (11, 42)],
    ],
}
STAND = {
    "head": (24, 8),
    "strokes": [
        [(24, 16), (24, 30)],
        [(24, 17), (18, 21), (17, 30)],
        [(24, 17), (30, 21), (31, 30)],
        [(24, 30), (20, 43)],
        [(24, 30), (28, 43)],
    ],
}


def pictogram(draw, figure, box, fill):
    """Draws a 48 x 48 pictogram into box (x, y, size) with round caps and joins."""
    x0, y0, size = box
    k = size / 48
    at = lambda p: (x0 + p[0] * k, y0 + p[1] * k)
    width = 5 * k
    for stroke in figure["strokes"]:
        points = [at(p) for p in stroke]
        draw.line(points, fill=fill, width=round(width), joint="curve")
        for px, py in points:
            draw.ellipse((px - width / 2, py - width / 2, px + width / 2, py + width / 2), fill=fill)
    hx, hy = at(figure["head"])
    r = 4.5 * k
    draw.ellipse((hx - r, hy - r, hx + r, hy + r), fill=fill)


def glow(size, center, radii, color, strength):
    """A soft elliptical glow of color, as an RGBA layer."""
    layer = Image.new("RGBA", size, color + (0,))
    falloff = Image.radial_gradient("L").resize((radii[0] * 2, radii[1] * 2), Image.BICUBIC)
    alpha = falloff.point(lambda v: max(0, round((1 - v / 255 / 0.7) * 255 * strength)))
    mask = Image.new("L", size, 0)
    mask.paste(alpha, (center[0] - radii[0], center[1] - radii[1]))
    layer.putalpha(mask)
    return layer


def draw_og(icon):
    """Open Graph image, 1200 x 630, in the look of the website (night band, signal, zebra)."""
    scale = 2
    width, height = 1200 * scale, 630 * scale
    s = lambda v: round(v * scale)
    night, glow_blue, zebra = (10, 26, 58), (27, 75, 140), (233, 238, 246)
    accent, muted = (75, 227, 193), (197, 208, 226)

    og = Image.new("RGBA", (width, height), night + (255,))
    og.alpha_composite(glow((width, height), (s(930), s(380)), (s(620), s(440)), glow_blue, 1.0))

    # Signal head: red (off) above, green (on) below, with the green light glowing.
    hx, hy, hw = s(840), s(64), s(232)
    pad, gap = s(22), s(18)
    lamp = hw - 2 * pad
    hh = pad * 2 + lamp * 2 + gap
    green_box = (hx + pad, hy + pad + lamp + gap, hx + pad + lamp, hy + pad + lamp * 2 + gap)
    halo = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(halo).rounded_rectangle(green_box, radius=s(30), fill=accent + (130,))
    og.alpha_composite(halo.filter(ImageFilter.GaussianBlur(s(34))))
    draw = ImageDraw.Draw(og)
    draw.rounded_rectangle((hx, hy, hx + hw, hy + hh), radius=s(44), fill=(8, 18, 38), outline=(34, 52, 90), width=s(2))
    red_box = (hx + pad, hy + pad, hx + pad + lamp, hy + pad + lamp)
    draw.rounded_rectangle(red_box, radius=s(30), fill=(58, 21, 23))
    draw.rounded_rectangle(green_box, radius=s(30), fill=(0, 128, 107))
    figure = round(lamp * 0.64)
    inset = (lamp - figure) // 2
    pictogram(draw, STAND, (red_box[0] + inset, red_box[1] + inset, figure), (92, 35, 38))
    pictogram(draw, WALK, (green_box[0] + inset, green_box[1] + inset, figure), (255, 255, 255))
    # Radio waves beside the head.
    wx, wy = hx + hw + s(14), hy + s(70)
    for i, r in enumerate((s(22), s(42), s(62))):
        draw.arc((wx - r, wy - r, wx + r, wy + r), start=-50, end=50, fill=accent, width=s(7))

    # Name and tagline.
    logo = rounded(icon.resize((s(72), s(72)), Image.LANCZOS))
    og.alpha_composite(logo, (s(80), s(70)))
    name = ImageFont.truetype(LATIN_FONT, s(44))
    draw.text((s(170), s(106)), "Aoshingo", font=name, fill="white", anchor="lm")
    headline = ImageFont.truetype(JAPANESE_FONT, s(76))
    draw.text((s(78), s(214)), "歩行者用信号を、", font=headline, fill="white", stroke_width=s(1.5), stroke_fill="white")
    draw.text((s(78), s(318)), "手のひらに。", font=headline, fill=accent, stroke_width=s(1.5), stroke_fill=accent)
    small = ImageFont.truetype(JAPANESE_FONT, s(28))
    draw.text((s(82), s(462)), "高度化PICS 対応・非公式・オープンソース", font=small, fill=muted)

    # Zebra crossing along the bottom edge.
    bar, top = s(60), height - s(44)
    for x in range(0, width, bar * 2):
        draw.rectangle((x, top, x + bar - 1, height), fill=zebra)

    # 256 colours with dithering keep the file small without visible banding in the glow.
    og = og.convert("RGB").resize((1200, 630), Image.LANCZOS)
    return og.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
