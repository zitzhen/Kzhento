#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Select the Kzhento Plymouth theme in an unpacked root tree.
#
# Split out of edit-plymouth.sh because it runs on the host after the chroot
# has been torn down: regenerating the initramfs is the last step of the theme
# change, and initramfs-tools needs /proc and /sys, which only exist inside a
# live chroot.
#
#   ./select-theme.sh <target root>
#
# Makes /etc/alternatives/default.plymouth point at the "minimal" (Kzhento)
# theme and rebuilds the initramfs of every kernel installed in <target root>.
# Requires root: the rebuild chroots into the image.

set -e

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

root=${1:-}
[ -n "$root" ] || die "Usage: $0 <target root>"
root=$(cd "$root" && pwd) || die "Target not found: $1"
root=${root%/}
[ "$root" = "/" ] && root=''

theme=/usr/share/plymouth/themes/minimal/minimal.plymouth
[ -f "$root$theme" ] || die "Theme not installed in target: $root$theme"

log "Pointing default.plymouth at the Kzhento theme"
alt="$root/etc/alternatives/default.plymouth"
install -d -m 0755 "$(dirname "$alt")"
rm -f "$alt"
ln -s ../../usr/share/plymouth/themes/minimal/minimal.plymouth "$alt"

[ -f "$root/etc/initramfs-tools/initramfs.conf" ] || {
    log "No initramfs-tools in target, skipping initramfs rebuild"
    exit 0
}

# The theme artwork lives in the initramfs, so an installed image keeps showing
# the old logo until the initramfs is rebuilt. Mount /proc and /sys for the
# duration of the chroot: both are required by update-initramfs.
log "Rebuilding initramfs inside $root"
cleanup() {
    set +e
    for m in /sys /proc; do
        if mountpoint -q "$root$m" 2>/dev/null; then
            umount "$root$m" 2>/dev/null || umount -l "$root$m" 2>/dev/null
        fi
    done
}
trap cleanup EXIT

# bind-mounting needs the mount point to exist; an unpacked tree made by
# unsquashfs has them, a hand-made one may not
install -d -m 0755 "$root/proc" "$root/sys"
mount --bind /proc "$root/proc" || die "Cannot mount $root/proc"
mount --bind /sys "$root/sys" || die "Cannot mount $root/sys"
chroot "$root" /bin/sh -c 'update-initramfs -u -k all' ||
    die "update-initramfs failed inside $root"

log "Done: default plymouth theme is $theme"
