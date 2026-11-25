#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Unit checks for edit-plymouth/render.py, the script that turns the logo into
# the boot splash artwork. Everything runs in a temporary directory and only
# reads the logo from LOGO_DIR; no root is needed and the suite itself never
# touches the network.
#
# Usage: bash tests/render.test.sh
#
# Environment:
#   LOGO_DIR   directory holding kzhento_transparent.png
#              (default: <repo>/logo, the build's download cache)
#
# The artwork is deliberately not committed (edit-logo.sh downloads it at build
# time), so a clean checkout has no logo. This suite checks the renderer, not
# the logo, so it skips - exit 0 with a note - when the source is absent rather
# than failing a PR that cannot possibly provide it.
#
# The assertions are deliberately coarse: the exact ring geometry is a drawing
# detail, but the properties below are what the boot screen actually needs.
#   - every asset is produced, at the expected sizes
#   - the throbber and the icon master are the same ringed mark, centred and
#     square, with no stray speck from the underline
#   - the watermark is the full logo, in the boot screen's colours; the icon
#     master keeps the logo's own colours, because it is drawn on the desktop
#     rather than on the black boot screen
#   - the source logo is never modified

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
RENDER="$REPO_DIR/edit-plymouth/render.py"
LOGO_DIR=${LOGO_DIR:-"$REPO_DIR/logo"}

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok  %s\n' "$*"; }
skip() {
    printf '..  %s\n' "$*"
    printf '\nrender checks skipped\n'
    exit 0
}

[ -f "$RENDER" ] || die "Missing: $RENDER"
if [ ! -f "$LOGO_DIR/kzhento_transparent.png" ]; then
    skip "No logo at $LOGO_DIR/kzhento_transparent.png; the artwork is downloaded, not committed"
fi

PY_BIN=${PYTHON:-}
if [ -z "$PY_BIN" ]; then
    for c in python3 /usr/bin/python3; do
        if "$c" -c 'import PIL' >/dev/null 2>&1; then
            PY_BIN=$c
            break
        fi
    done
fi
[ -n "$PY_BIN" ] || die "Pillow is required (apt-get install python3-pil) or set PYTHON="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. The source logo must survive the render byte for byte. A renderer that
#    writes to its input would corrupt the build cache for every later run.
before=$(sha256sum "$LOGO_DIR/kzhento_transparent.png" | cut -d' ' -f1)

"$PY_BIN" "$RENDER" "$LOGO_DIR" "$TMP" >"$TMP/log" 2>&1 ||
    die "render.py failed: $(cat "$TMP/log")"
ok "render.py runs"

[ -f "$TMP/watermark.png" ] || die "render.py did not write watermark.png"
[ -f "$TMP/throbber.png" ] || die "render.py did not write throbber.png"
[ -f "$TMP/mark.png" ] || die "render.py did not write mark.png"
ok "all three assets written"

after=$(sha256sum "$LOGO_DIR/kzhento_transparent.png" | cut -d' ' -f1)
[ "$before" = "$after" ] || die "render.py modified its input logo"
ok "source logo untouched"

# 2. Shape checks, done in Python so the assertions can express geometry.
"$PY_BIN" - "$TMP" <<'PY' || exit 1
import sys
from pathlib import Path

from PIL import Image

out = Path(sys.argv[1])
watermark = Image.open(out / "watermark.png").convert("RGBA")
throbber = Image.open(out / "throbber.png").convert("RGBA")
mark = Image.open(out / "mark.png").convert("RGBA")

fail = []


def check(condition, message):
    if not condition:
        fail.append(message)


def ink_pixels(image, threshold=40):
    alpha = image.getchannel("A")
    return [(x, y) for y in range(image.height) for x in range(image.width)
            if alpha.getpixel((x, y)) > threshold]


# --- watermark: the whole logo, wide and flat, in the boot screen's colours.
check(watermark.size == (512, 154),
      f"watermark is {watermark.size}, expected (512, 154)")
check(not watermark.getchannel("A").getextrema()[1:] == 0,
      "watermark is fully transparent")

px = watermark.load()
whites = blues = 0
for y in range(0, watermark.height, 2):
    for x in range(0, watermark.width, 2):
        r, g, b, a = px[x, y]
        if a < 128:
            continue
        if r > 200 and g > 200 and b > 200:
            whites += 1
        elif b > r + 25:
            blues += 1
# The wordmark is the white part, the ring and underline the blue part. Both
# have to be there, in roughly the proportion of the artwork.
check(whites > 500, f"watermark has too little white ink ({whites} sampled pixels)")
check(blues > 500, f"watermark has too little blue accent ({blues} sampled pixels)")
check(whites > blues / 4, "watermark is mostly accent: the wordmark did not come out white")

# --- throbber: square, the ringed mark alone, no speck floating beside it.
check(throbber.size == (48, 48), f"throbber is {throbber.size}, expected (48, 48)")
ink = ink_pixels(throbber)
check(len(ink) > 300, f"throbber has almost no ink ({len(ink)} pixels)")

box = throbber.getchannel("A").getbbox() or (0, 0, 0, 0)
left, top, right, bottom = box
width, height = right - left, bottom - top
# Centring the mark on a square canvas and scaling it to the frame means the ink
# reaches both edges: anything smaller is a mark that lost part of itself.
check(max(width, height) >= 46,
      f"throbber mark is {width}x{height}, expected to fill the 48x48 frame")
check(abs(width - height) <= 4,
      f"throbber mark is not square-ish: {width}x{height}")
check(min(width, height) >= 40,
      f"throbber mark is {width}x{height} in a 48x48 frame, expected near full size")

# The mark is hollow in the middle of the ring, but the "Kz" sits there, so a
# horizontal scan through the vertical centre has to hit ink inside the ring.
middle = throbber.height // 2
row = [throbber.getpixel((x, middle))[3] for x in range(throbber.width)]
inside = [a for x, a in enumerate(row) if 12 <= x < throbber.width - 12]
check(any(a > 40 for a in inside),
      "throbber is an empty ring: the inner mark is missing")

# --- icon master: the same square mark, at 512 px, in the logo's own colours.
#
# The desktop draws this on light and dark panels, so it is not recoloured for a
# black background: the ink keeps the logo's blue, which would be lost if white
# on the light Breeze panel.
check(mark.size == (512, 512), f"icon master is {mark.size}, expected (512, 512)")

# It has to be the *same* cut-out as the spinner, not a second, drifting one.
# Both are the same square, so scaling the master down to the frame size has to
# reproduce the frame's alpha exactly: any difference is a real disagreement (a
# different crop, or a speck kept in one and dropped from the other), not an
# artefact of comparing two renders.
mark_alpha = mark.getchannel("A").resize(throbber.size, Image.LANCZOS)
throbber_alpha = throbber.getchannel("A")
diff = sum(1 for a, b in zip(mark_alpha.tobytes(), throbber_alpha.tobytes()) if abs(a - b) > 128)
check(diff == 0,
      f"icon master is not the throbber's mark ({diff} of "
      f"{throbber.width * throbber.height} pixels differ at 48 px)")

mark_box = mark.getchannel("A").getbbox() or (0, 0, 0, 0)
mw, mh = mark_box[2] - mark_box[0], mark_box[3] - mark_box[1]
# The ringed mark is wider than it is tall (the ring sweeps out to the right), so
# on the square canvas it spans the full width and leaves the taller margin
# above and below. That is the point of the square canvas: the mark keeps its
# centre, which is what the About page lines it up by.
check(mw >= mark.width - 2, f"icon mark is {mw}x{mh}, expected to span the 512 px canvas")
check(0.8 * mw <= mh <= mw, f"icon mark is {mw}x{mh}, not the mark's proportions")
# Centred: the left and right margins around the ink must match, since the icon
# is what the About page lines up next to the product name.
check(abs(mark_box[0] - (mark.width - mark_box[2])) <= 4,
      f"icon mark is off-centre: left {mark_box[0]}, right {mark.width - mark_box[2]}")

# The two renderings of the mark differ in colour, not in shape: the boot
# screen's variant repaints the ink with the boot palette (white and a dimmed
# accent, 48/130/230), while the desktop's keeps the artwork's own blues. Mean
# ink colour is therefore the direct answer to "was this recoloured for a black
# background?", and it is stable against anti-aliasing because both variants
# share the exact same alpha.
mpx = mark.load()
mr = mg = mb = mark_ink = 0
for y in range(0, mark.height, 2):
    for x in range(0, mark.width, 2):
        r, g, b, a = mpx[x, y]
        if a < 250:
            continue
        mark_ink += 1
        mr += r
        mg += g
        mb += b
check(mark_ink > 10000, f"icon master has almost no opaque ink ({mark_ink} samples)")

mean = (mr / mark_ink, mg / mark_ink, mb / mark_ink)
# The boot palette's accent is (48, 130, 230); the logo's own blue is #006cfd,
# i.e. blue 252 with next to no red. The blue channel is the wider, quieter gap
# (252 against 230), so it carries the check; the red channel is checked only as
# a sanity bound.
check(mean[2] > 245 and mean[0] < 45,
      f"icon master's ink is {tuple(round(v) for v in mean)}, not the logo's blue "
      f"(#006cfd): it was repainted for a black background")
check(mean[1] < 200 and mean[2] > mean[1] > mean[0],
      f"icon master's ink is not a blue: {tuple(round(v) for v in mean)}")

if fail:
    for message in fail:
        print(f"XX  {message}", file=sys.stderr)
    sys.exit(1)
print(f"ok  watermark 512x154, throbber ink {len(ink)} px, mark {width}x{height}, "
      f"icon master {mw}x{mh}, mean ink {tuple(round(v) for v in mean)}")
PY

ok "artwork shape, colours and centring"

printf '\nAll render checks passed\n'
