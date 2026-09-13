#!/usr/bin/env python3
"""Rasterise the Troupe mask into the icon formats that cannot be SVG.

    python scripts/brand-icons.py

Writes `apps/troupe_plane/priv/static/brand/favicon.ico` (16/32/48) and
`apple-touch-icon.png` (180). Everything else about the brand is SVG and is
authored by hand next to them; only these two formats force a bitmap.

The geometry is the mask as `docs/design/themes/*.tokens.json` defines it, at the
three stroke weights the kits use: 3.4 at 16px with the eyes flattened to bars,
3.0 above it. Colours are the Signal theme's dark values, because a favicon is
pasted onto a browser chrome we do not control and the dark mark reads on both.

Requires Pillow. It is not part of the build: run it when the mark changes and
commit what it writes, the same bargain as `mix troupe.admin.assets`.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "apps" / "troupe_plane" / "priv" / "static" / "brand"

# Signal, dark. The tile is `bg.sunken`, the edge and open eye `text.primary`, the
# filled half `status.waiting.solid` — the reserved colour — and the eye cut out of
# it `text.inverse`.
TILE = (11, 13, 16, 255)
INK = (236, 239, 243, 255)
RESERVED = (255, 92, 184, 255)
CUT = (10, 11, 13, 255)

SS = 8  # supersample factor; the mask is all curves and 48 units wide.


def quad(p0, p1, p2, steps=24):
    """Flatten one quadratic segment, dropping the start point (the previous one)."""
    out = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        out.append(
            (
                u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
            )
        )
    return out


def mask_outline(left, top, right, bottom, shoulder, chin):
    """The silhouette: a squared crown, straight sides, a curve to the chin."""
    mid = (left + right) / 2
    pts = [(left, shoulder)]
    pts += quad((left, shoulder), (left, top), (mid, top))
    pts += quad((mid, top), (right, top), (right, shoulder))
    pts.append((right, chin))
    pts += quad((right, chin), (right, bottom - 2), (mid, bottom))
    pts += quad((mid, bottom), (left, bottom - 2), (left, chin))
    return pts


def lens(x0, x1, y, lift):
    """An eye: two arcs meeting at the corners."""
    mid = (x0 + x1) / 2
    pts = [(x0, y)]
    pts += quad((x0, y), (mid, y - lift), (x1, y))
    pts += quad((x1, y), (mid, y + lift), (x0, y))
    return pts


def scaled(points, size):
    k = size * SS / 48
    return [(x * k, y * k) for x, y in points]


def render(size, stroke, geometry, eyes, tile_radius):
    """One icon, drawn on a 48 grid at `SS` times the requested pixel size."""
    px = size * SS
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    if tile_radius is None:
        draw.rectangle([0, 0, px, px], fill=TILE)
    else:
        draw.rounded_rectangle(
            scaled([(2, 2), (46, 46)], size), radius=tile_radius * size * SS / 48, fill=TILE
        )

    outline = scaled(mask_outline(*geometry), size)
    draw.polygon(outline, fill=TILE)

    # The filled half is the outline clipped to everything right of the seam.
    half = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    ImageDraw.Draw(half).polygon(outline, fill=RESERVED)
    keep = Image.new("L", (px, px), 0)
    ImageDraw.Draw(keep).rectangle([px / 2, 0, px, px], fill=255)
    img.paste(half, (0, 0), Image.composite(half.getchannel("A"), keep, keep))

    width = max(1, round(stroke * size * SS / 48))
    draw.line(outline + [outline[0]], fill=INK, width=width, joint="curve")

    for shape, colour in eyes:
        if shape[0] == "lens":
            draw.polygon(scaled(lens(*shape[1:]), size), fill=colour)
        else:
            _, x, y, w, h, r = shape
            draw.rounded_rectangle(
                scaled([(x, y), (x + w, y + h)], size),
                radius=r * size * SS / 48,
                fill=colour,
            )

    return img.resize((size, size), Image.LANCZOS)


# 16px: the heavier stroke, and the eyes flattened to bars because two arcs three
# pixels apart are one grey smudge.
SMALL = dict(
    stroke=3.4,
    geometry=(12, 10, 36, 39, 17, 25),
    eyes=[
        (("rect", 16, 21, 5.5, 3.4, 1.7), INK),
        (("rect", 26.5, 21, 5.5, 3.4, 1.7), CUT),
    ],
)

# 32px and up: the kit's medium weight, eyes as lenses.
MEDIUM = dict(
    stroke=3.0,
    geometry=(11, 9, 37, 40, 16, 25),
    eyes=[
        (("lens", 15.8, 22.6, 21, 2.4), INK),
        (("lens", 25.4, 32.2, 21, 2.4), CUT),
    ],
)


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    icons = [
        render(16, tile_radius=3, **SMALL),
        render(32, tile_radius=6, **MEDIUM),
        render(48, tile_radius=7, **MEDIUM),
    ]
    icons[-1].save(
        OUT / "favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48)],
        append_images=icons[:-1],
    )

    # Apple rounds the corners itself and does not composite transparency, so this
    # one is full bleed and opaque.
    touch = render(180, tile_radius=None, **MEDIUM).convert("RGB")
    touch.save(OUT / "apple-touch-icon.png", optimize=True)

    for name in ("favicon.ico", "apple-touch-icon.png"):
        print(f"wrote {(OUT / name).relative_to(ROOT)} ({(OUT / name).stat().st_size} bytes)")


if __name__ == "__main__":
    main()
