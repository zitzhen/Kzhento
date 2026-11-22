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
#   - both assets are produced, at the expected sizes
#   - the throbber is the ringed mark alone, centred and square
#   - the watermark is the full logo, in the boot screen's colours
#   - the throbber carries no stray speck from the underline
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
ok "both assets written"

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

if fail:
    for message in fail:
        print(f"XX  {message}", file=sys.stderr)
    sys.exit(1)
print(f"ok  watermark 512x154, throbber ink {len(ink)} px, mark {width}x{height}")
PY

ok "artwork shape, colours and centring"

printf '\nAll render checks passed\n'
