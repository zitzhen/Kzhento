#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Remove the stock Kubuntu wallpapers from the image.
#
# Why this file: Kubuntu 26.04 ships exactly three wallpapers in
# kubuntu-wallpapers - "Kubuntu" (the day/night gear), "Kubuntu Black" and
# "Kubuntu Light" (kubuntu-wallpapers 26.04.3's description says the others
# were dropped upstream) - and they are the last place the Kubuntu wordmark
# stays on screen once the Welcome Center, the icons and the boot splash are
# branded. The default is moved to Patak by ../edit-wallpaper/
# set-default-wallpaper.sh; this script takes the stock packages' artwork out.
#
# Removing the directories is not enough. dpkg still owns those paths, so a
# later `apt install --reinstall kubuntu-wallpapers` (or an upgrade of the
# package) puts the artwork back and the Wallpaper KCM offers it again. A dpkg
# path filter is the supported way to make an unpack skip files: the package
# stays installed - it is a hard dependency of kubuntu-settings-desktop, so it
# cannot simply be purged - while its wallpaper directories never land. The
# filter is installed in the image, not only applied here, so it also covers
# unpacks that happen after this build. The pattern ends in "/*": excluding the
# directory itself makes dpkg fail with "cannot create directory ... No such
# file or directory" on the next unpack, while excluding its contents leaves an
# empty directory behind and succeeds.
#
# Usage:
#   sudo ./remove-kubuntu-wallpapers.sh <target root>
#
# Removing a wallpaper that is not installed is a skip, so the step is
# idempotent and also works on a tree that already had them removed.

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

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

root=${1:-/}
root=$(cd "$root" && pwd) || die "Target not found: $1"
root=${root%/}
[ "$root" = "/" ] && root=''

# The three wallpaper kpackages kubuntu-wallpapers 26.04.3 installs. A filter
# for a name that is not installed would be dead weight but still correct; the
# list is the one the image actually ships.
WALLPAPERS="Kubuntu KubuntuBlack KubuntuLight"

log "Removing the stock Kubuntu wallpapers"
for w in $WALLPAPERS; do
    dir="$root/usr/share/wallpapers/$w"
    if [ ! -d "$dir" ]; then
        log "  $w is not installed, nothing to remove"
        continue
    fi
    rm -rf "$dir"
    log "  removed /usr/share/wallpapers/$w"
done

# Keep the artwork out of the image on every later unpack of the package. The
# directory has to exist even when there is no dpkg in the target, so the file
# can be read by hand as documentation of what was removed.
CFG="$root/etc/dpkg/dpkg.cfg.d"
install -d -m 0755 "$CFG"
FILTER="$CFG/zhento-wallpapers"
{
    printf '# Kzhento: the Kubuntu wallpapers are removed from this image.\n'
    printf '# A dpkg path filter is the supported way to keep the files of an\n'
    printf '# installed package out of the image: the package stays (it is a\n'
    printf '# dependency of kubuntu-settings-desktop) but its wallpaper\n'
    printf '# directories are skipped on unpack, so an upgrade or a reinstall\n'
    printf '# cannot put the Kubuntu artwork back.\n'
    printf '# Written by edit-wallpaper/remove-kubuntu-wallpapers.sh.\n'
    # The "/*" suffix matters: excluding the directory itself makes dpkg fail
    # with "cannot create directory ... No such file or directory" when the
    # package is unpacked, while excluding its contents leaves an empty
    # directory and succeeds. Both forms are fnmatch patterns, not shell globs.
    for w in $WALLPAPERS; do
        printf 'path-exclude=/usr/share/wallpapers/%s/*\n' "$w"
    done
} >"$FILTER"
chmod 0644 "$FILTER"
log "  installed the dpkg path filter: /etc/dpkg/dpkg.cfg.d/zhento-wallpapers"

# A removed wallpaper whose directory is still referenced elsewhere is a black
# desktop, not a cosmetic leftover: the default has to have moved first. Only
# the wallpaper defaults are checked here; the look-and-feel thumbnails are
# separate artwork files, not the kpackage.
for f in "$root"/usr/share/plasma/look-and-feel/*/contents/defaults; do
    [ -f "$f" ] || continue
    if grep -q '^Image=\(Kubuntu\|KubuntuBlack\|KubuntuLight\)$' "$f"; then
        die "$f still names a removed wallpaper as its default; run set-default-wallpaper.sh first"
    fi
done

log "Done: the stock Kubuntu wallpapers are gone"
