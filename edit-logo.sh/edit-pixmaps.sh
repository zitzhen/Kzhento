#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Switch /usr/share/pixmaps/ubuntu-logo-text-dark.png to the Kzhento wordmark.
#
# Why this file: /usr/share/plymouth/themes/spinner/watermark.png is a symlink
# into /usr/share/pixmaps, and the spinner/bgrt themes draw their watermark from
# it. /usr/share/pixmaps is also what the Ubuntu wordmark files are installed
# for, so replacing the drawing here covers the boot screen and any other
# consumer of the same file while leaving the filenames untouched.
#
# Usage:
#   sudo ./edit-pixmaps.sh <logo dir> <target root>
#
# The PNG is rendered by ../edit-plymouth/render.py so there is one definition
# of the artwork; this script only places the bytes and records the original.

set -e

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
log() { printf '==> %s\n' "$*"; }

case "${1:-}" in
-h | --help)
    sed -n '6,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# switch to script dir, so relative paths always work
cd "$(dirname "$0")" || exit 1

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

RENDER=$(cd "$(dirname "$0")/../edit-plymouth" 2>/dev/null && pwd)/render.py
[ -f "$RENDER" ] || die "render.py not found next to edit-plymouth/"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log "Rendering K-Zhento wordmark"
"$PY_BIN" "$RENDER" "$LOGO_DIR" "$WORK" >/dev/null || die "Failed to render artwork"

PIXMAP="$root/usr/share/pixmaps/ubuntu-logo-text-dark.png"
[ -f "$PIXMAP" ] || die "Not found: $PIXMAP"

# Keep the upstream wordmark once, so the original look can be restored.
if [ ! -e "$PIXMAP.zhento-orig" ]; then
    cp -a "$PIXMAP" "$PIXMAP.zhento-orig"
fi

log "Installing K-Zhento wordmark into /usr/share/pixmaps"
install -m 0644 "$WORK/watermark.png" "$PIXMAP"

log "Done: $PIXMAP is now the Kzhento wordmark"
