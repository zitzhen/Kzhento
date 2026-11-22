#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Replace the Kubuntu notification branding with Kzhento.
#
# kubuntu-notification-helper puts a notification into the Plasma notification
# area on the first login; clicking it opens the "Welcome Center" window. Both
# its title and its body come from the package's own translation files, so
# overriding them means overriding the gettext catalogue for the notification's
# domain.
#
# The catalogue is looked up in the locale directory, then in Gettext's
# LOCALEDIR (which is what a .mo installed by us can use), and only then in the
# built-in msgid. Putting our .mo first therefore wins without touching the
# vendor file, and `apt upgrade kubuntu-notification-helper` cannot undo it.
#
# Usage:
#   sudo ./edit-notification.sh <target root>
#
# The .mo lives in ../edit-plymouth/tools, next to the other build-time helpers.

set -e

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
log() { printf '==> %s\n' "$*"; }

case "${1:-}" in
-h | --help)
    sed -n '6,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

root=${1:-/}
root=$(cd "$root" && pwd) || die "Target not found: $1"
root=${root%/}
[ "$root" = "/" ] && root=''

PAYLOAD=$(cd "$(dirname "$0")/po" && pwd)
[ -d "$PAYLOAD" ] || die "Translations not found: $PAYLOAD"

log "Installing Kzhento notification translations"
# Each catalogue goes into the locale directory of its own language: gettext
# looks for <localedir>/<lang>/LC_MESSAGES/<domain>.mo, so zh_CN.mo filed under
# en/ would never be read.
found=0
for mo in "$PAYLOAD"/*.mo; do
    [ -f "$mo" ] || continue
    found=1
    lang=$(basename "$mo" .mo)
    dest="$root/usr/share/locale/$lang/LC_MESSAGES"
    install -d -m 0755 "$dest"
    install -m 0644 "$mo" "$dest/kubuntu-notification-helper.mo"
    log "  $dest/kubuntu-notification-helper.mo"
done
[ "$found" -eq 1 ] || die "No .mo files in $PAYLOAD"

# The notification helper is only hidden when its desktop entry, the launcher
# autostart entry and the notification itself carry the new name; the
# autostart entry is what actually starts it, the desktop entry is what the
# launcher shows. Entries the package does not ship are skipped, and only the
# untranslated Name= is rewritten: translated names come from the same
# catalogue and are handled by the .mo files above.
log "Renaming the notification helper entries"
for entry in "$root/usr/share/applications/kubuntu-notification-helper.desktop" \
    "$root/etc/xdg/autostart/kubuntu-notification-helper.desktop"; do
    [ -f "$entry" ] || continue
    sed -i 's/^Name=.*/Name=K-Zhento Notifications/' "$entry"
    log "  $entry"
done

log "Done"
