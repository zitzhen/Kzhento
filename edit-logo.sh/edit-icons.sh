#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Replace the stock KDE "start-here-kde" icon with the Kzhento mark.
#
# Why this file: the "About this System" page (kcm_about-distro) draws its logo
# through Kirigami.Icon, and /etc/xdg/kcm-about-distrorc names that icon as
# "start-here-kde": kinfocenter hands the string to QIcon::fromTheme(), which
# only resolves icon names, never paths. The same icon name is what Plasma uses
# for the application launcher. Installing the artwork under that name is
# therefore what makes the About page - and the launcher - draw Kzhento.
#
# What is installed: a PNG per size directory, cut from the same ringed "Kz"
# mark the boot splash uses (edit-plymouth/render.py renders it at 512 px). The
# stock KDE bundles draw that icon as SVG, so the SVGs are kept as
# <name>.zhento-orig and removed: leaving them next to the PNGs would let a
# loader with a different preference keep drawing the KDE logo.
#
# Usage:
#   sudo ./edit-icons.sh <logo dir> <target root>
#
# Environment:
#   PYTHON   python3 interpreter with Pillow (default: auto-detect)

set -e

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
log() { printf '==> %s\n' "$*"; }

case "${1:-}" in
-h | --help)
    sed -n '6,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# switch to script dir, so relative paths always work
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

LOGO_DIR=${1:-}
root=${2:-/}
[ -n "$LOGO_DIR" ] || die "Usage: $0 <logo dir> <target root>"
[ -f "$LOGO_DIR/kzhento_transparent.png" ] || die "Logo not found: $LOGO_DIR/kzhento_transparent.png"
root=$(cd "$root" && pwd) || die "Target not found: $2"
root=${root%/}
[ "$root" = "/" ] && root=''

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

RENDER="$SCRIPT_DIR/../edit-plymouth/render.py"
[ -f "$RENDER" ] || die "render.py not found next to edit-plymouth/"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log "Rendering the K-Zhento mark"
"$PY_BIN" "$RENDER" "$LOGO_DIR" "$WORK" >/dev/null || die "Failed to render artwork"

ICONS="$root/usr/share/icons"
[ -d "$ICONS" ] || die "No icon theme under $ICONS"

# install_icon <size directory> <pixels>: one start-here-kde.png.
#
# The stock file is recorded once and then removed, whichever extension it had:
# Breeze ships .svg, a theme installed by a package may ship .png. Leaving
# either behind would keep a loader that prefers the old artwork on screen.
#
# Removing the SVG has a second consequence: the stock theme also uses it as a
# *target*. start-here-kde-plasma.svg and start-here-symbolic.svg are symlinks to
# start-here-kde.svg in several size directories, so deleting the file would
# leave the launcher's Plasma icon broken. Those links are pointed at the copy of
# the stock artwork instead, which is what they drew before.
install_icon() {
    dir=$1
    size=$2

    for old in "$dir"/start-here-kde.svg "$dir"/start-here-kde.png; do
        [ -e "$old" ] || [ -L "$old" ] || continue
        [ -e "$old.zhento-orig" ] || [ -L "$old.zhento-orig" ] ||
            cp -a "$old" "$old.zhento-orig"

        for link in "$dir"/*.svg; do
            [ -L "$link" ] || continue
            case "$(readlink "$link")" in
            start-here-kde.svg) ln -sfn start-here-kde.svg.zhento-orig "$link" ;;
            esac
        done

        rm -f "$old"
    done

    "$PY_BIN" - "$WORK" "$dir/start-here-kde.png" "$size" <<'PY'
import sys
from pathlib import Path

from PIL import Image

work, dest, size = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
Image.open(work / "mark.png").convert("RGBA").resize((size, size), Image.LANCZOS).save(dest)
PY
    chmod 0644 "$dir/start-here-kde.png"
}

# Collect "<directory> <pixels>" for every size the image's icon themes use.
#
# Breeze lists its Places icons by directory in index.theme, and the @2x/@3x
# names are HiDPI variants of the same icon. A stock Kubuntu makes those
# directories symlinks to the plain one, so several names resolve to a single
# directory: writing each in turn would leave the last one's size there, e.g. a
# 24 px image in the directory the theme reads for 16 px icons. The list is
# therefore collapsed by real path, keeping the largest size asked for.
#
# places/96 is declared scalable up to 256, so it gets a 256 px image and the
# loader scales down from there.
plan="$WORK/plan"
: >"$plan"
for theme in breeze breeze-dark; do
    for dir in 16 16@2x 16@3x 22 22@2x 22@3x 24 24@2x 24@3x 32 48 64 96; do
        path="$ICONS/$theme/places/$dir"
        [ -d "$path" ] || continue
        case "$dir" in
        *@2x) size=$((${dir%@2x} * 2)) ;;
        *@3x) size=$((${dir%@3x} * 3)) ;;
        96) size=256 ;;
        *) size=$dir ;;
        esac
        printf '%s %s\n' "$(cd "$path" && pwd -P)" "$size" >>"$plan"
    done
done

# hicolor is the fallback every toolkit reads, so the icon is also there at the
# sizes the desktop actually asks for: 16/24/48 for menus and lists, 128 for the
# About page (Kirigami.Units.iconSizes.enormous), 256/512 for HiDPI and for
# anything that wants a large copy.
for dir in 16x16 24x24 32x32 48x48 64x64 128x128 256x256 512x512; do
    path="$ICONS/hicolor/$dir/places"
    [ -d "$path" ] || continue
    printf '%s %s\n' "$(cd "$path" && pwd -P)" "${dir%x*}" >>"$plan"
done

awk '{
    if (!($1 in best)) {
        order[++n] = $1
        best[$1] = $2
    } else if ($2 > best[$1]) {
        best[$1] = $2
    }
}
END { for (i = 1; i <= n; i++) print order[i], best[order[i]] }' "$plan" >"$WORK/unique"

installed=0
while read -r dir size; do
    install_icon "$dir" "$size"
    installed=$((installed + 1))
done <"$WORK/unique"

[ "$installed" -gt 0 ] || die "No icon size directory found under $ICONS"

# A cache that lists a size directory's files would still point at the old
# artwork. Only an existing cache is touched: hicolor ships one, the Breeze
# bundles do not, and creating a new one here would be a file nothing in the
# image asked for - Qt (which Plasma and Kirigami.Icon use) reads the
# directories directly.
for theme in hicolor breeze breeze-dark; do
    cache="$ICONS/$theme/icon-theme.cache"
    [ -f "$cache" ] || continue
    if command -v gtk-update-icon-cache >/dev/null 2>&1 &&
        gtk-update-icon-cache -f -t -q "$ICONS/$theme" >/dev/null 2>&1; then
        continue
    fi
    rm -f "$cache"
done

log "Done: start-here-kde is the Kzhento mark ($installed size directories)"
