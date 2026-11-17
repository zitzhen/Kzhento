#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only

# Usage:
#   sudo ./replace-grub.sh                  # auto-detect /boot/grub/grub.cfg on this machine
#   sudo ./replace-grub.sh <target grub.cfg> # specify target (e.g. an unpacked ISO tree)

set -e

# switch to script dir, so the relative grub.cfg path always works
cd "$(dirname "$0")" || exit 1

if [ ! -f grub.cfg ]; then
    echo "grub.cfg not found, exiting" >&2
    exit 1
fi

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

# Target: prefer the argument, otherwise auto-detect the local grub.cfg
if [ -n "${1:-}" ]; then
    target=$1
    if [ ! -f "$target" ]; then
        echo "Target not found: $target" >&2
        exit 1
    fi
elif [ -f /boot/grub/grub.cfg ]; then
    target=/boot/grub/grub.cfg
elif [ -f /boot/grub2/grub.cfg ]; then
    target=/boot/grub2/grub.cfg
else
    echo "/boot/grub/grub.cfg not found, exiting" >&2
    exit 1
fi

# Back up the original file for rollback on error
backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$target" "$backup" || {
    echo "backup fail error!" >&2
    exit 1
}

cp -f grub.cfg "$target" || {
    echo "copy fail error!" >&2
    exit 1
}
sync

echo "Backed up to: $backup"
echo "Done! Replace grub.cfg OK! -> $target"
