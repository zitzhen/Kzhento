#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Brand the "About this System" page of KDE System Settings (kcm_about-distro).
#
# That module reads its logo, product name, version and website from
# kcm-about-distrorc, falling back to /etc/os-release:
#
#   LogoPath   default os.logo(), i.e. the LOGO= key of os-release
#   Name       default os.name(), i.e. NAME=
#   Version    default os.versionId(), i.e. VERSION_ID=
#   Website    default os.homeUrl(), i.e. HOME_URL=
#
# Shipping the rc file is enough to brand the page, and it keeps the page
# independent of the os-release spelling (NAME= is used by other tools, so it
# is left alone). The module is installed by kinfocenter, which owns the file
# as a conffile; writing it here only takes effect once kinfocenter is
# installed, which is why this is a build step and not an install-app script.
#
# Usage:
#   sudo ./edit-about-system.sh                 # this system, or inside chroot
#   sudo ./edit-about-system.sh <target root>   # e.g. an unpacked root directory

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

# switch to script dir, so the relative path always works
cd "$(dirname "$0")" || exit 1

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

[ -f kcm-about-distrorc ] || die "kcm-about-distrorc not found in $PWD"

root=${1:-}
case "$root" in
'' | /) root='' ;;
*/) root=${root%/} ;;
esac

dest="$root/etc/xdg/kcm-about-distrorc"

log "Writing $dest"
install -d -m 0755 "$(dirname "$dest")"
# 0644 and root:root: the module reads it for every user, nobody needs to write.
install -m 0644 kcm-about-distrorc "$dest"

# The page only exists once kinfocenter is installed. Writing the file early is
# harmless, but knowing about a missing kinfocenter is useful when the branding
# does not show up in the ISO.
if [ ! -d "$root/usr/share/kpackage/kcms/kcm_about-distro" ] &&
    ! ls "$root"/usr/lib/*/qt6/plugins/plasma/kcms/systemsettings/kcm_about-distro.so >/dev/null 2>&1; then
    printf '..  kinfocenter is not installed in the target yet; the branding takes effect once it is\n' >&2
fi

log "Done: About this System shows the K-Zhento branding"
