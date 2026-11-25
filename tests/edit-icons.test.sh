#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for edit-logo.sh/edit-icons.sh, the step that puts the Kzhento mark in
# place of the stock start-here-kde artwork.
#
# What this guards, and why each part is a real failure mode:
#
#   - the root guard: the script writes under /usr/share/icons, so it must not
#     run for an unprivileged caller (id is mocked, the target is a temp dir)
#   - a missing logo and a target without icon themes fail loudly instead of
#     reporting success
#   - every size directory the image's themes declare gets a PNG, at the size
#     that directory is declared for
#   - the stock SVG is moved aside, not left next to the PNG: a loader that
#     prefers SVG would otherwise keep drawing the KDE logo
#   - a theme whose @2x/@3x directories are symlinks to the plain one gets one
#     image per real directory, at the largest size asked for - writing each
#     name in turn used to leave a 48 px image where the theme reads 16 px
#   - hicolor, the fallback every toolkit reads, is covered too
#
# Nothing here needs root or the network: `id -u` is mocked and the logo comes
# from LOGO_DIR (default <repo>/logo); the suite skips when it is absent, like
# render.test.sh, because the artwork is downloaded at build time.
#
# Usage: bash tests/edit-icons.test.sh
#
# Environment:
#   LOGO_DIR   directory holding kzhento_transparent.png (default: <repo>/logo)

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_DIR/edit-logo.sh/edit-icons.sh"
LOGO_DIR=${LOGO_DIR:-"$REPO_DIR/logo"}

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

[ -f "$SCRIPT" ] || fail "missing input: $SCRIPT"
[ -x "$SCRIPT" ] || fail "not executable: $SCRIPT"

if [ ! -f "$LOGO_DIR/kzhento_transparent.png" ]; then
    printf '..  no logo at %s; the artwork is downloaded, not committed\n' \
        "$LOGO_DIR/kzhento_transparent.png"
    printf '\nedit-icons checks skipped\n'
    exit 0
fi

for c in python3 sh; do
    command -v "$c" >/dev/null 2>&1 || {
        printf '..  missing command: %s\n' "$c"
        exit 0
    }
done
python3 -c 'import PIL' 2>/dev/null || {
    printf '..  Pillow is not installed\n'
    exit 0
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Mock id so the root guard can be exercised without real privileges.
ROOT_BIN="$TMP/root-bin"
NONROOT_BIN="$TMP/nonroot-bin"
mkdir -p "$ROOT_BIN" "$NONROOT_BIN"
printf '#!/bin/sh\necho 0\n' >"$ROOT_BIN/id"
printf '#!/bin/sh\necho 1000\n' >"$NONROOT_BIN/id"
chmod +x "$ROOT_BIN/id" "$NONROOT_BIN/id"

svg_stub='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16"/></svg>'

# make_root <dir>: an image tree with the icon themes build.sh brands. The
# @2x/@3x directories are symlinks, exactly like a stock Kubuntu, and hicolor
# has no start-here-kde at all, because the stock one lives in the KDE bundles.
make_root() {
    local root=$1
    local base="$root/usr/share/icons"
    mkdir -p "$base/breeze/places" "$base/hicolor"
    for n in 16 22 24 32 48 64 96; do
        mkdir -p "$base/breeze/places/$n"
        printf '%s\n' "$svg_stub" >"$base/breeze/places/$n/start-here-kde.svg"
        # The stock theme points these at start-here-kde.svg, so removing that
        # file would leave them dangling.
        ln -s start-here-kde.svg "$base/breeze/places/$n/start-here-kde-plasma.svg"
        ln -s start-here-kde.svg "$base/breeze/places/$n/start-here-symbolic.svg"
        ln -s "$n" "$base/breeze/places/$n@2x"
        ln -s "$n" "$base/breeze/places/$n@3x"
    done
    # breeze-dark inherits breeze's dimensions but ships its own place icons.
    mkdir -p "$base/breeze-dark"
    cp -a "$base/breeze/places" "$base/breeze-dark/places"
    printf '[Icon Theme]\nName=Breeze\nInherits=hicolor\n' >"$base/breeze/index.theme"
    printf '[Icon Theme]\nName=Breeze Dark\nInherits=breeze,hicolor\n' >"$base/breeze-dark/index.theme"
    for d in 16x16 24x24 32x32 48x48 64x64 128x128 256x256 512x512; do
        mkdir -p "$base/hicolor/$d/places"
    done
    printf '[Icon Theme]\nName=Hicolor\n' >"$base/hicolor/index.theme"
}

# png_size <file>: "<width>x<height>" of a PNG, without trusting the filename.
png_size() {
    python3 - "$1" <<'PY'
import sys
from PIL import Image
print("%dx%d" % Image.open(sys.argv[1]).size)
PY
}

# 1. The root guard runs before anything is written.
make_root "$TMP/nonroot"
before=$(find "$TMP/nonroot" -type f | sort | xargs cksum 2>/dev/null | cksum)
set +e
out=$(PATH="$NONROOT_BIN:$PATH" sh "$SCRIPT" "$LOGO_DIR" "$TMP/nonroot" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "non-root call exited $rc, expected 1"
case "$out" in *'root is required'*) ;; *) fail "root guard missing: $out" ;; esac
after=$(find "$TMP/nonroot" -type f | sort | xargs cksum 2>/dev/null | cksum)
[ "$before" = "$after" ] || fail "the script wrote files as a non-root caller"
ok "refuses to run without root, without writing anything"

# 2. Missing inputs fail loudly.
make_root "$TMP/noicons"
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$SCRIPT" "$LOGO_DIR" "$TMP/noicons/does-not-exist" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a missing target exited $rc, expected 1"
case "$out" in *'Target not found'*) ;; *) fail "missing target diagnostic absent: $out" ;; esac
ok "rejects a target that does not exist"

empty="$TMP/emptyroot"
mkdir -p "$empty/usr/share"
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$SCRIPT" "$LOGO_DIR" "$empty" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a target without icon themes exited $rc, expected 1"
case "$out" in *'No icon theme'*) ;; *) fail "missing icon theme diagnostic absent: $out" ;; esac
ok "rejects a target with no icon themes"

bogus="$TMP/boguslogo"
mkdir -p "$bogus"
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$SCRIPT" "$bogus" "$TMP/nonroot" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a missing logo exited $rc, expected 1"
case "$out" in *'Logo not found'*) ;; *) fail "missing logo diagnostic absent: $out" ;; esac
ok "rejects a missing logo"

# 3. A real run installs the mark everywhere it is needed.
root="$TMP/image"
make_root "$root"
PATH="$ROOT_BIN:$PATH" sh "$SCRIPT" "$LOGO_DIR" "$root" >"$TMP/log" 2>&1 ||
    fail "installer failed: $(cat "$TMP/log")"
ok "installs into a stock-like icon tree"

# Breeze: every declared size directory has a PNG, at the size it declares.
# The @2x/@3x links resolve to the plain directory, so each group shares one
# image; the largest size the group asks for is the one that has to be there.
for theme in breeze breeze-dark; do
    for n in 16 22 24 32 48 64 96; do
        for suffix in '' '@2x' '@3x'; do
            dir="$root/usr/share/icons/$theme/places/$n$suffix"
            [ -f "$dir/start-here-kde.png" ] ||
                fail "$theme/places/$n$suffix has no start-here-kde.png"
            [ ! -e "$dir/start-here-kde.svg" ] ||
                fail "$theme/places/$n$suffix still has the stock start-here-kde.svg"
            [ -f "$dir/start-here-kde.svg.zhento-orig" ] ||
                fail "$theme/places/$n$suffix did not keep the stock SVG as .zhento-orig"
            # The plasma launcher icon is a different icon name and keeps its
            # own (stock) artwork - but it is a symlink to the SVG that was just
            # removed, so it has to be re-pointed or the launcher breaks.
            [ -L "$dir/start-here-kde-plasma.svg" ] ||
                fail "$theme/places/$n$suffix lost start-here-kde-plasma.svg"
            [ -e "$dir/start-here-kde-plasma.svg" ] ||
                fail "$theme/places/$n$suffix start-here-kde-plasma.svg dangles"
        done
    done
done
ok "every breeze/breeze-dark size dir has a PNG and no stock SVG remains"

# Sizes: 16 -> 48 px (16@3x is the largest of the group), 96 -> 256 px.
for theme in breeze breeze-dark; do
    [ "$(png_size "$root/usr/share/icons/$theme/places/16/start-here-kde.png")" = "48x48" ] ||
        fail "$theme 16px dir does not hold a 48x48 image (it holds $(png_size "$root/usr/share/icons/$theme/places/16/start-here-kde.png"))"
    [ "$(png_size "$root/usr/share/icons/$theme/places/22/start-here-kde.png")" = "66x66" ] ||
        fail "$theme 22px dir is not 66x66"
    [ "$(png_size "$root/usr/share/icons/$theme/places/24/start-here-kde.png")" = "72x72" ] ||
        fail "$theme 24px dir is not 72x72"
    [ "$(png_size "$root/usr/share/icons/$theme/places/32/start-here-kde.png")" = "32x32" ] ||
        fail "$theme 32px dir is not 32x32"
    [ "$(png_size "$root/usr/share/icons/$theme/places/48/start-here-kde.png")" = "48x48" ] ||
        fail "$theme 48px dir is not 48x48"
    [ "$(png_size "$root/usr/share/icons/$theme/places/64/start-here-kde.png")" = "64x64" ] ||
        fail "$theme 64px dir is not 64x64"
    [ "$(png_size "$root/usr/share/icons/$theme/places/96/start-here-kde.png")" = "256x256" ] ||
        fail "$theme scalable 96px dir is not 256x256"
done
ok "each size dir holds an image of the right size (symlinked HiDPI dirs take the largest)"

# hicolor: the About page asks for 128 px (Kirigami's "enormous"), and the
# fallback theme has to have it at that size or it would scale from 16.
for d in 16x16 24x24 32x32 48x48 64x64 128x128 256x256 512x512; do
    f="$root/usr/share/icons/hicolor/$d/places/start-here-kde.png"
    [ -f "$f" ] || fail "hicolor/$d/places has no start-here-kde.png"
    [ "$(png_size "$f")" = "$((${d%x*}))x$((${d%x*}))" ] ||
        fail "hicolor/$d holds $(png_size "$f")"
done
ok "hicolor covers 16-512 px, including the About page's 128 px"

# The image is the mark, not a blank square: it has transparent corners, ink
# spread over the canvas and a blue dominant colour. The very centre is
# transparent - the mark is a hollow ring with the "Kz" inside it, so a
# centre-pixel test would be testing the artwork, not the installation.
python3 - "$root/usr/share/icons/hicolor/128x128/places/start-here-kde.png" <<'PY' || exit 1
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGBA")
w, h = im.size
problems = []
if im.getpixel((0, 0))[3] != 0:
    problems.append("corner is opaque")
inks = [im.getpixel((x, y)) for y in range(h) for x in range(w) if im.getpixel((x, y))[3] > 200]
# An installed mark, not a logo dropped in un-cropped: the ink has to reach all
# four edges of the square canvas it was fitted to.
if not inks:
    problems.append("no ink at all")
else:
    xs = [x for y in range(h) for x in range(w) if im.getpixel((x, y))[3] > 200]
    ys = [y for y in range(h) for x in range(w) if im.getpixel((x, y))[3] > 200]
    if max(xs) - min(xs) < w - 4 or max(ys) - min(ys) < h * 0.8:
        problems.append(f"ink spans {max(xs) - min(xs)}x{max(ys) - min(ys)}, not the canvas")
if len(inks) < (w * h) // 20:
    problems.append(f"only {len(inks)} opaque pixels")
blues = [p for p in inks if p[2] > p[0] + 25]
if len(blues) < len(inks) * 0.85:
    problems.append(f"only {len(blues)} of {len(inks)} ink pixels are blue")
if problems:
    print("  " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"ok  128 px icon is the mark: {len(inks)} ink pixels, {len(blues)} of them blue")
PY
ok "the installed image is the Kzhento mark, not a placeholder"

# 3b. The re-pointed links draw the stock artwork, not the Kzhento PNG: they are
#     a different icon (the Plasma launcher's), and silently branding them would
#     be a decision this step was not asked to make.
grep -q '<svg' "$root/usr/share/icons/breeze/places/48/start-here-kde-plasma.svg" ||
    fail "start-here-kde-plasma.svg no longer draws the stock SVG"
ok "symlinks that targeted the stock SVG were re-pointed, not left dangling"

# 4. A theme with real HiDPI directories (not symlinks) gets one image each, at
#    the size that directory asks for. This is the case a package-installed
#    theme can have, and the one that made the "collapse by real path" bug
#    dangerous to fix by dropping the @2x names altogether.
plain="$TMP/plain"
plain_base="$plain/usr/share/icons"
mkdir -p "$plain_base"
for n in 16 22 24 32 48 64 96; do
    mkdir -p "$plain_base/breeze/places/$n"
    printf '%s\n' "$svg_stub" >"$plain_base/breeze/places/$n/start-here-kde.svg"
done
mkdir -p "$plain_base/breeze/places/16@2x" "$plain_base/breeze/places/16@3x"
printf '%s\n' "$svg_stub" >"$plain_base/breeze/places/16@2x/start-here-kde.svg"
printf '%s\n' "$svg_stub" >"$plain_base/breeze/places/16@3x/start-here-kde.svg"
mkdir -p "$plain_base/hicolor"
printf '[Icon Theme]\nName=Breeze\n' >"$plain_base/breeze/index.theme"
PATH="$ROOT_BIN:$PATH" sh "$SCRIPT" "$LOGO_DIR" "$plain" >"$TMP/log2" 2>&1 ||
    fail "installer failed on real HiDPI dirs: $(cat "$TMP/log2")"
for pair in "16:16" "16@2x:32" "16@3x:48"; do
    dir=${pair%%:*}
    want=${pair##*:}
    got=$(png_size "$plain_base/breeze/places/$dir/start-here-kde.png")
    [ "$got" = "${want}x${want}" ] ||
        fail "real HiDPI dir $dir holds $got, expected ${want}x${want}"
done
ok "separate HiDPI directories each keep their own size"

# 5. Re-running is idempotent: the .zhento-orig backup is taken once and keeps
#    the stock artwork, not an earlier Kzhento PNG.
orig_sum=$(cksum "$root/usr/share/icons/breeze/places/48/start-here-kde.svg.zhento-orig")
PATH="$ROOT_BIN:$PATH" sh "$SCRIPT" "$LOGO_DIR" "$root" >/dev/null 2>&1 ||
    fail "second run failed"
[ "$orig_sum" = "$(cksum "$root/usr/share/icons/breeze/places/48/start-here-kde.svg.zhento-orig")" ] ||
    fail "the stock-artwork backup was overwritten by a later run"
grep -q '<svg' "$root/usr/share/icons/breeze/places/48/start-here-kde.svg.zhento-orig" ||
    fail "the backup is not the stock SVG"
ok "a second run keeps the original backup intact"

printf '\nAll edit-icons checks passed\n'
