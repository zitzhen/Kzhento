#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Make an installed wallpaper the default everywhere Plasma picks one.
#
# Why this file: "the default wallpaper" is not one setting. Plasma resolves it
# from three places, and a build that changes only one of them still shows a
# different picture depending on where the user looks:
#
#   1. /usr/share/plasma/look-and-feel/<theme>/contents/defaults
#      the [Wallpaper] Image= entry, used when that look-and-feel theme is
#      applied (what a fresh account starts with);
#   2. .../contents/layouts/*.js
#      the layout script writes the wallpaper into the new account's
#      appletsrc. Kubuntu's themes hard-code their edition there, with the
#      day/night marker, so the Image line has to be rewritten too;
#   3. /usr/share/kubuntu-default-settings/kf5-settings/kscreenlockerrc
#      the lock screen, which has its own [Greeter][Wallpaper] setting and
#      otherwise keeps drawing the Kubuntu day/night wallpaper.
#
# The wallpaper is named as an installed kpackage (a directory under
# /usr/share/wallpapers with a metadata.json), so nothing has to be copied into
# the image and no binary is stored in this repository. The default is "Patak"
# (Áron Kovács, 寒溪), which Kubuntu 26.04 ships in
# plasma-workspace-wallpapers at up to 5120x2880.
#
# Only entries that name a stock Kubuntu wallpaper (the ones
# remove-kubuntu-wallpapers.sh takes out) or the chosen wallpaper are rewritten.
# Breeze's own "Next" default is upstream's artwork for that theme and is left
# alone.
#
# Usage:
#   sudo ./set-default-wallpaper.sh <target root>
#
# Environment:
#   WALLPAPER   installed wallpaper name (default: Patak)
#
# Day/night is turned off for the entries that are rewritten: Patak is a plain
# image, and leaving DynamicMode=1 would blend its images_dark in at dusk.

set -e

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
log() { printf '==> %s\n' "$*"; }

case "${1:-}" in
-h | --help)
    sed -n '6,36p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

root=${1:-/}
root=$(cd "$root" && pwd) || die "Target not found: $1"
root=${root%/}
[ "$root" = "/" ] && root=''

NAME=${WALLPAPER:-Patak}

# The name ends up in config values, so it is restricted to what a kpackage
# directory may be called.
case "$NAME" in
'' | *[!A-Za-z0-9_-]*) die "Not a valid wallpaper name: $NAME" ;;
esac

WALLPAPERS="$root/usr/share/wallpapers"
PKG="$WALLPAPERS/$NAME"
[ -d "$PKG" ] || die "Wallpaper not installed in the target: $PKG"
[ -f "$PKG/metadata.json" ] || die "Not a wallpaper kpackage (no metadata.json): $PKG"
URL="file:///usr/share/wallpapers/$NAME"

# The kpackage has to carry a picture, or the desktop turns flat grey while the
# build still reports success.
if ! find "$PKG/contents" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.svg' -o -name '*.svgz' \) 2>/dev/null | grep -q .; then
    die "Wallpaper has no image files: $PKG/contents"
fi

# The entries this step rewrites: the stock Kubuntu wallpapers it removes, or
# the target itself (so a re-run keeps them pointed at the same place).
STOCK='Kubuntu\|KubuntuBlack\|KubuntuLight'
matched=0

# ---------------------------------------------------------------------------
# 1. Look-and-feel defaults: [Wallpaper] Image=<name>
# ---------------------------------------------------------------------------
log "Setting [Wallpaper] Image=$NAME in the look-and-feel defaults"
for f in "$root"/usr/share/plasma/look-and-feel/*/contents/defaults; do
    [ -f "$f" ] || continue
    grep -q "^Image=\($STOCK\|$NAME\)\$" "$f" || continue
    matched=$((matched + 1))
    # Keep the stock file once so the change can be diffed or reverted.
    [ -e "$f.zhento-orig" ] || cp -a "$f" "$f.zhento-orig"
    sed -i "s#^Image=.*\$#Image=$NAME#" "$f"
    log "  $f"
done

# ---------------------------------------------------------------------------
# 2. Layout scripts: writeConfig('Image', ...) and DynamicMode
#
# This is what a fresh account actually gets on first login; the defaults file
# above is the fallback, so both have to agree.
# ---------------------------------------------------------------------------
log "Pointing the look-and-feel layout scripts at $NAME"
for f in "$root"/usr/share/plasma/look-and-feel/*/contents/layouts/*.js; do
    [ -f "$f" ] || continue
    grep -q "writeConfig( 'Image', '[^']*' )" "$f" || continue
    grep -q "writeConfig( 'Image', '[^']*/wallpapers/\($STOCK\)\(\#[^']*\)\?' )" "$f" ||
        continue
    matched=$((matched + 1))
    [ -e "$f.zhento-orig" ] || cp -a "$f" "$f.zhento-orig"
    sed -i "s#writeConfig( 'Image', '[^']*' )#writeConfig( 'Image', '$URL' )#g" "$f"
    # Without this the "day-night" wallpapers keep cross-fading over the new
    # image at dusk.
    sed -i "s#writeConfig( 'DynamicMode', [0-9][0-9]* )#writeConfig( 'DynamicMode', 0 )#g" "$f"
    log "  $f"
done

# ---------------------------------------------------------------------------
# 3. Lock screen
# ---------------------------------------------------------------------------
LOCK="$root/usr/share/kubuntu-default-settings/kf5-settings/kscreenlockerrc"
if [ -f "$LOCK" ] &&
    grep -q "^\(Image\|PreviewImage\)=file:///usr/share/wallpapers/\($STOCK\)" "$LOCK"; then
    log "Setting the lock screen wallpaper to $NAME"
    matched=$((matched + 1))
    [ -e "$LOCK.zhento-orig" ] || cp -a "$LOCK" "$LOCK.zhento-orig"
    # Image=, PreviewImage= and DynamicMode= share the
    # [Greeter][Wallpaper][org.kde.image][General] section.
    sed -i \
        -e "s#^Image=.*\$#Image=$URL#" \
        -e "s#^PreviewImage=.*\$#PreviewImage=$URL#" \
        -e "s#^DynamicMode=.*\$#DynamicMode=0#" "$LOCK"
else
    log "No lock screen wallpaper to change, skipping it"
fi

# Nothing to rewrite means this is not a Kubuntu desktop image, or the defaults
# moved; either way the build would ship a wallpaper it did not set.
[ "$matched" -gt 0 ] ||
    die "No look-and-feel default names a Kubuntu wallpaper or $NAME; nothing was set"

# ---------------------------------------------------------------------------
# A dangling reference is a black desktop with no error message, and the stock
# wallpapers are removed by a sibling step. Check the result instead of
# trusting the edits above.
# ---------------------------------------------------------------------------
log "Checking that every wallpaper reference resolves"
missing=0
for f in "$root"/usr/share/plasma/look-and-feel/*/contents/defaults \
    "$root"/usr/share/plasma/look-and-feel/*/contents/layouts/*.js \
    "$LOCK"; do
    [ -f "$f" ] || continue
    for ref in $(sed -n "s#.*wallpapers/\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*#\1#p" "$f" | sort -u); do
        [ -d "$WALLPAPERS/$ref" ] && continue
        printf '   %s -> missing /usr/share/wallpapers/%s\n' "$f" "$ref" >&2
        missing=$((missing + 1))
    done
done
[ "$missing" -eq 0 ] || die "$missing wallpaper reference(s) point at a directory that is not installed"

log "Done: the default wallpaper is $NAME ($URL)"
