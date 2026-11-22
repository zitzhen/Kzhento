#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Install the Kzhento Plymouth boot theme into a target system.
#
# The base image boots with "spinner" (or "bgrt" on machines that export an
# ACPI BGRT): a black screen with the Ubuntu wordmark as watermark. Both
# themes render through ImageDir=/usr/share/plymouth/themes/spinner, so the
# artwork on screen is
#
#   throbber-*.png   the spinner frames
#   watermark.png    a dpkg symlink to /usr/share/pixmaps/ubuntu-logo-text-dark.png
#
# This script:
#   1. renders the Kzhento artwork from the logo PNGs (render.py)
#   2. overwrites the spinner frames and the watermark symlink in that theme,
#      so the stock theme names keep working ("spinner" stays valid)
#   3. installs a Kzhento theme of its own as /usr/share/plymouth/themes/minimal
#      (the two-step module draws animation-*.png and watermark.png from its
#      ImageDir; the stock throbber frames are not carried over, they belong to
#      the "spinner" script) and selects it; the selection is applied by
#      ../select-theme.sh, which also rebuilds the initramfs (the theme is
#      copied into it at build time)
#
# Usage:
#   sudo ./edit-plymouth.sh                  # this system, or inside chroot
#   sudo ./edit-plymouth.sh <target root>    # e.g. an unpacked root directory
#
# Environment:
#   LOGO_DIR   directory holding kzhento.png / kzhento_transparent.png
#              (default: ../logo, populated by edit-logo/edit-logo.sh)
#   PYTHON     python3 interpreter with Pillow (default: auto-detect)

set -e

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
log() { printf '==> %s\n' "$*"; }

case "${1:-}" in
-h | --help)
    sed -n '6,31p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# switch to script dir, so relative paths always work
cd "$(dirname "$0")" || exit 1

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

root=${1:-}
case "$root" in
'' | /) root='' ;;
*/) root=${root%/} ;;
esac

SCRIPT_DIR=$PWD
THEME_FILE="$SCRIPT_DIR/plymouth/minimal.plymouth"
[ -f "$THEME_FILE" ] || die "Theme payload not found: $THEME_FILE"

# PNG encoding needs Pillow. On an unpacked tree we run on the host, because the
# chroot may not have python3 installed yet.
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

SPINNER="$root/usr/share/plymouth/themes/spinner"
[ -f "$SPINNER/spinner.plymouth" ] || die "spinner theme not found: $SPINNER"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log "Rendering Kzhento artwork from $LOGO_DIR"
"$PY_BIN" "$SCRIPT_DIR/render.py" "$LOGO_DIR" "$WORK" || die "Failed to render artwork"

# The artwork replaces files owned by the plymouth package. They are recorded
# in /var/lib/dpkg/info/plymouth.md5sums, so the next apt upgrade of plymouth
# would overwrite them again; the packaged versions are therefore kept next to
# the modified ones by ../select-theme.sh, and the md5 records are refreshed
# there as well.

# ---------------------------------------------------------------------------
# 1. Spinner frames. The stock frames are white-on-transparent rounded squares
#    rotating around the logo; the animation is driven by the sequence, not by
#    the content, so every frame gets the same Kzhento icon.
# ---------------------------------------------------------------------------
log "Replacing spinner artwork"
count=0
for frame in "$SPINNER"/throbber-*.png; do
    [ -e "$frame" ] || continue
    install -m 0644 "$WORK/throbber.png" "$frame"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || die "No throbber-*.png in $SPINNER"

# watermark.png is a symlink into /usr/share/pixmaps; replace the link with a
# regular file so the boot screen no longer depends on the upstream wordmark in
# that directory (which edit-pixmaps.sh replaces for the rest of the system).
log "Replacing watermark"
rm -f "$SPINNER/watermark.png"
install -m 0644 "$WORK/watermark.png" "$SPINNER/watermark.png"

# ---------------------------------------------------------------------------
# 2. Dedicated theme: the spinner theme with the Kzhento watermark. Keeping a
#    theme of our own means the boot screen no longer depends on whether
#    "spinner" or "bgrt" wins the default.plymouth alternative.
# ---------------------------------------------------------------------------
log "Installing theme into /usr/share/plymouth/themes/minimal"
THEME_DIR="$root/usr/share/plymouth/themes/minimal"
rm -rf "$THEME_DIR"
install -d -m 0755 "$THEME_DIR"
install -m 0644 "$THEME_FILE" "$THEME_DIR/minimal.plymouth"
install -m 0644 "$WORK/watermark.png" "$THEME_DIR/watermark.png"
# The two-step module reads its assets from ImageDir; carry over the ones the
# stock theme keeps next to its frames (password prompt, keyboard, etc.).
#
# The frames are not carried over: throbber-*.png belongs to the stock theme's
# own script, and two-step draws animation-*.png instead. One copy of the mark
# is enough, because the icon does not turn; the stock frames only encoded the
# rotation.
for asset in "$SPINNER"/*; do
    case "${asset##*/}" in
    throbber-*.png | watermark.png | spinner.plymouth) continue ;;
    *.png | *.svg) install -m 0644 "$asset" "$THEME_DIR/${asset##*/}" ;;
    esac
done
install -m 0644 "$WORK/throbber.png" "$THEME_DIR/animation-0001.png"

# ---------------------------------------------------------------------------
# 3. Select the theme. update-alternatives keeps /etc/alternatives consistent;
#    when it cannot run (unpacked tree on the host, no dpkg database) fall back
#    to writing the link directly, which is what ../select-theme.sh does anyway.
# ---------------------------------------------------------------------------
log "Registering the Kzhento theme as default.plymouth"
if [ -z "$root" ] && command -v update-alternatives >/dev/null 2>&1; then
    update-alternatives --install \
        /etc/alternatives/default.plymouth default.plymouth \
        /usr/share/plymouth/themes/minimal/minimal.plymouth 200 >/dev/null 2>&1 || true
    update-alternatives --set default.plymouth \
        /usr/share/plymouth/themes/minimal/minimal.plymouth >/dev/null 2>&1 || true
fi
ALT="$root/etc/alternatives/default.plymouth"
install -d -m 0755 "$(dirname "$ALT")"
if [ -z "$root" ] && command -v update-alternatives >/dev/null 2>&1 &&
    update-alternatives --query default.plymouth 2>/dev/null |
    grep -q '/usr/share/plymouth/themes/minimal/minimal.plymouth'; then
    :
else
    rm -f "$ALT"
    ln -s ../../usr/share/plymouth/themes/minimal/minimal.plymouth "$ALT"
fi

log "Done: theme installed. Run select-theme.sh <root> to rebuild the initramfs"
