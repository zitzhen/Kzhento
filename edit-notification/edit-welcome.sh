#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Replace the "Welcome Center" first page with K-Zhento's own.
#
# Why this file: plasma-welcome shows a first-login tour whose first page is
# /usr/share/plasma/plasma-welcome/extra-pages/01-Kubuntu.qml. That page is not
# translated content - its heading, its body text and both of its images (the
# Kubuntu wordmark and a Donate badge linking to kubuntu.org) are written into
# the QML itself, and no gettext catalogue can override them, because upstream
# ships no plasma-welcome catalogue for the untranslated source language.
# Overwriting the file is therefore the only way to change what it says.
#
# ../edit-notification.sh already brands the notification that opens this
# window; this step is what brands the window itself.
#
# Usage:
#   sudo ./edit-welcome.sh <target root>
#
# The stock page is kept as 01-Kubuntu.qml.zhento-orig, so the change can be
# undone and a plasma-welcome upgrade can be diffed against what it replaced.

set -e

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
log() { printf '==> %s\n' "$*"; }

case "${1:-}" in
-h | --help)
    sed -n '6,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

root=${1:-/}
root=$(cd "$root" && pwd) || die "Target not found: $1"
root=${root%/}
[ "$root" = "/" ] && root=''

PAGE="$SCRIPT_DIR/plasma-welcome/01-Kzhento.qml"
[ -f "$PAGE" ] || die "Page payload not found: $PAGE"

PAGES="$root/usr/share/plasma/plasma-welcome/extra-pages"
STOCK="$PAGES/01-Kubuntu.qml"

if [ ! -d "$PAGES" ]; then
    # plasma-welcome is not installed on every Kubuntu flavour; without it there
    # is no first-login tour to brand, so this is a skip, not a failure.
    log "No plasma-welcome in the target ($PAGES); skipping the Welcome Center page"
    exit 0
fi

# The images the page and its replacement use are rendered from the logo, so
# Pillow is needed even though this script writes no PNG itself. The artwork is
# rendered by ../edit-plymouth/render.py, the single definition of it.
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

LOGO_DIR=${LOGO_DIR:-"$SCRIPT_DIR/../logo"}
[ -f "$LOGO_DIR/kzhento_transparent.png" ] ||
    die "Logo not found: $LOGO_DIR/kzhento_transparent.png (run edit-logo/edit-logo.sh first)"

RENDER=$(cd "$SCRIPT_DIR/../edit-plymouth" 2>/dev/null && pwd)/render.py
[ -f "$RENDER" ] || die "render.py not found next to edit-plymouth/"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log "Rendering the K-Zhento wordmark for the page"
"$PY_BIN" "$RENDER" "$LOGO_DIR" "$WORK" >/dev/null || die "Failed to render artwork"

# Keep the stock page once, before the first overwrite. A second run must not
# replace the backup with our own page.
if [ -f "$STOCK" ] && [ ! -e "$STOCK.zhento-orig" ]; then
    cp -a "$STOCK" "$STOCK.zhento-orig"
    log "  kept the stock page as $STOCK.zhento-orig"
fi

log "Installing the K-Zhento Welcome Center page"
install -m 0644 "$WORK/logo.png" "$PAGES/kzhento-logo.png"
install -m 0644 "$PAGE" "$STOCK"

# The page is replaced in place, at the name plasma-welcome already looks for, so
# the backup has to sit elsewhere: a second 01-*.qml in this directory would be
# enumerated as one more page. .zhento-orig is not a .qml extension, and
# plasma-welcome only picks up *.qml, so it is never shown - but it is also gone
# from the list of pages if the file is edited into place rather than swapped.
# Say so instead of letting the next reader wonder why the backup "works".
[ -f "$STOCK" ] || die "The page was not installed: $STOCK"
grep -q 'K-Zhento' "$STOCK" || die "The installed page does not mention K-Zhento"

log "Done: the Welcome Center first page is K-Zhento's"
