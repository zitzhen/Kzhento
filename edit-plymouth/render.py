#!/usr/bin/env python3
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Render the Kzhento Plymouth artwork from the logo PNGs:
#
#   <out>/watermark.png   the whole logo (ring + wordmark + underline), white
#                         ink and blue accents, for the bottom watermark of the
#                         "minimal" theme and of the stock spinner theme
#   <out>/throbber.png    the ringed "Kz" mark only, square, used as the spinner
#                         frame in every throbber-*.png
#
# Usage: render.py <logo dir> <output dir>
#
# The source is 1774x887 RGBA. The ink is charcoal grey (#3a3a3a) and the
# accents are a vivid blue (#0077ff), both on a transparent background. The boot
# screen is black, so the charcoal would vanish: the ink is repainted white and
# the accents are kept blue but darkened to a shade that still reads as the
# brand blue on black. Only alpha decides where ink is, so the artwork keeps its
# shape whatever the colours become.

import sys
from pathlib import Path

from PIL import Image

WATERMARK_WIDTH = 512
THROBBER_SIZE = 48

# The boot screen's ink: white, and a blue dim enough not to glare on black.
INK = (255, 255, 255)
ACCENT = (48, 130, 230)

# A pixel counts as blue accent when blue clearly dominates red. The logo's
# accents are #0077ff, the ink is neutral grey (r = g = b), so this never flips.
BLUE_MARGIN = 25
# Manhattan distance (sum of per-channel differences) from the background
# colour below which a pixel is background. Only used for an opaque source, to
# tell the anti-aliased edge apart from the drawing.
BACKGROUND_DISTANCE = 90
# Alpha threshold for "this pixel has ink"; below it a pixel is background.
INK_ALPHA = 40
# Share of the ink below which a connected patch is a speck rather than part of
# the mark. The smallest real part is the "z" at a few percent of the ink, the
# underline leftovers are well under one percent, so the cut-off sits between.
SPECK_SHARE = 0.002


def load_source(path):
    """Return (ink mask, coloured image) painted for a black background."""
    img = Image.open(path).convert("RGBA")
    if img.getchannel("A").getextrema()[0] < 255:
        # Cut-out source: the alpha channel already says where the ink is, and
        # the colours only have to be repainted.
        return img.getchannel("A"), recolour(img)

    # Opaque source: the corner colour is the background. Pixels are separated
    # by distance from that colour, so the anti-aliased edge stays a distance
    # away from the background instead of being taken for ink.
    bg = img.getpixel((0, 0))[:3]
    mask = Image.new("L", img.size, 0)
    coloured = Image.new("RGBA", img.size)
    src, ink, dst = img.load(), mask.load(), coloured.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, _ = src[x, y]
            distance = abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2])
            if distance <= BACKGROUND_DISTANCE:
                continue
            colour = ACCENT if b > r + BLUE_MARGIN else INK
            ink[x, y] = 255
            dst[x, y] = colour + (255,)
    return mask, coloured


def recolour(img):
    """Repaint the artwork for a black background, keeping its alpha.

    The alpha channel is what gives the strokes their soft edge, so it is left
    alone while the colour is replaced: neutral pixels (the charcoal ink) turn
    white, and pixels where blue dominates (the accents) turn the accent blue.
    """
    mask = img.getchannel("A")
    coloured = Image.new("RGBA", img.size)
    src, ink, dst = img.load(), mask.load(), coloured.load()
    for y in range(img.height):
        for x in range(img.width):
            alpha = ink[x, y]
            if alpha <= INK_ALPHA:
                continue
            r, g, b, _ = src[x, y]
            colour = ACCENT if b > r + BLUE_MARGIN else INK
            dst[x, y] = colour + (alpha,)
    return coloured


def fit(image, width):
    height = max(1, round(image.height * width / image.width))
    return image.resize((width, height), Image.LANCZOS)


def ring_bottom(icon_mask):
    """Last row of the ring, i.e. the row where the ring's stroke turns back up.

    Below the ring the window holds only the underline, which is thinner than the
    ring and travels to the right as it goes down. So a row is read as two parts:
    the ink up to the widest empty stretch, which is the ring while the ring is
    there, and the ink after it, which is the underline. The ring's last row is
    the last one whose left part still reaches out to the right.

    A window flatter than the ring cannot hold the ring, so a ring that fills the
    window returns the full height.
    """
    width, height = icon_mask.size
    rows = []
    for y in range(height):
        run, widest, middle = 0, 0, 0
        for x in range(width):
            if icon_mask.getpixel((x, y)) > INK_ALPHA:
                run = 0
            else:
                run += 1
                if run > widest:
                    widest, middle = run, x - run // 2
        left = [x for x in range(middle) if icon_mask.getpixel((x, y)) > INK_ALPHA]
        rows.append((max(left) if left else -1, middle))

    most = max(middle for _, middle in rows)
    for y in range(height - 1, round(height * 0.5), -1):
        reach, middle = rows[y]
        if reach >= 0 and middle <= most // 2:
            return y + 1
    return height


def icon_split(mask):
    """Right edge of the ringed mark.

    The mark keeps sweeping down to the right after its top half, so the widest
    gap between the ring and the wordmark is searched in the band above the
    middle: there the ring and the "K" are separated, while the underline that
    spans the full width is excluded.
    """
    width, height = mask.size
    top, bottom = round(height * 0.1), round(height * 0.55)
    step = max(1, (bottom - top) // 300)
    best_end, best_len = width, 0
    run = 0
    for x in range(width):
        if any(mask.getpixel((x, y)) > INK_ALPHA for y in range(top, bottom, step)):
            run = 0
            continue
        run += 1
        if run > best_len and (x - run) < width // 2:
            best_len, best_end = run, x + 1
    return best_end if best_len else width


def drop_specks(image):
    """Erase ink patches too small to be part of the mark.

    The crop that isolates the ringed mark still catches the first few pixels of
    the underline where it sweeps down to the right, and those pixels end up as
    a floating dot in a 48 px spinner frame. The mark is drawn in long strokes,
    so every real part of it - the ring, the "K", the "z" - is a patch of
    thousands of pixels, while the leftovers are a handful. Patches under
    SPECK_SHARE of the ink are therefore dropped.

    The mark is not one patch: the "Kz" sits inside the ring without touching
    it, so all the large patches are kept, not just the largest one.

    The scan runs on the ink mask, and the pixels are copied over afterwards so
    the colour channels stay untouched.
    """
    width, height = image.size
    mask = image.getchannel("A")
    ink = mask.load()
    seen = [[False] * width for _ in range(height)]
    patches = []
    for start in range(width * height):
        x0, y0 = start % width, start // width
        if seen[y0][x0] or ink[x0, y0] <= INK_ALPHA:
            continue
        seen[y0][x0] = True
        patch, queue = [], [(x0, y0)]
        while queue:
            x, y = queue.pop()
            patch.append((x, y))
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < width and 0 <= ny < height and not seen[ny][nx]:
                    if ink[nx, ny] > INK_ALPHA:
                        seen[ny][nx] = True
                        queue.append((nx, ny))
        patches.append(patch)

    total = sum(len(patch) for patch in patches)
    kept = Image.new("L", image.size, 0)
    keep = kept.load()
    for patch in patches:
        if len(patch) < total * SPECK_SHARE:
            continue
        for x, y in patch:
            keep[x, y] = 255
    return Image.composite(image, Image.new("RGBA", image.size, (0, 0, 0, 0)), kept)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: render.py <logo dir> <output dir>")

    logo_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    source = logo_dir / "kzhento_transparent.png"
    if not source.is_file():
        sys.exit(f"XX  logo not found: {source}")

    mask, coloured = load_source(source)
    bbox = mask.getbbox()
    if bbox is None:
        sys.exit(f"XX  logo has no visible ink: {source}")

    # Watermark: the full logo, scaled to a fixed width.
    mark = fit(coloured.crop(bbox), WATERMARK_WIDTH)
    mark.save(out_dir / "watermark.png")

    # Spinner frame: the ringed mark only, on a square transparent canvas so the
    # rotation centre stays the centre of the mark. The ring is the tallest thing
    # in the artwork, so its bottom is looked up in a window as wide as it is
    # tall; the underline then shows up as a bare gap under the ring, while the
    # wordmark, which starts further right, stays out of that window. The right
    # edge of the mark comes from the widest gap in the band where the ring and
    # the "K" are apart. Both numbers are taken over the same window: taken over
    # the whole artwork the gap search would run into the wordmark's letters.
    height = bbox[3] - bbox[1]
    window = mask.crop((bbox[0], bbox[1], bbox[0] + 2 * height, bbox[3]))
    ring = ring_bottom(window)
    split = icon_split(window.crop((0, 0, window.width, ring)))
    icon = coloured.crop((bbox[0], bbox[1], bbox[0] + split, bbox[1] + ring))
    icon_bbox = icon.getbbox()
    if icon_bbox is not None:
        icon = icon.crop(icon_bbox)
    icon = drop_specks(icon)
    icon_bbox = icon.getbbox()
    if icon_bbox is not None:
        icon = icon.crop(icon_bbox)
    side = max(icon.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(icon, ((side - icon.width) // 2, (side - icon.height) // 2))
    fit(square, THROBBER_SIZE).save(out_dir / "throbber.png")

    print(f"==> watermark.png {mark.width}x{mark.height}, throbber.png {THROBBER_SIZE}x{THROBBER_SIZE}")


if __name__ == "__main__":
    main()
