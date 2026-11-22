#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Write /etc/default/useradd so that every account created after the image is
# built gets /bin/zsh as its login shell.
#
# The shipped useradd file is copied over the target without merging, exactly
# like edit-os-release/edit.sh does for os-release. The file is the whole
# default: SHELL=/bin/zsh, plus a commented record of the remaining shadow
# defaults (GROUP, HOME, INACTIVE, EXPIRE, CREATE_MAIL_SPOOL).
#
# This only covers accounts that do not exist yet. Accounts already in the
# image are handled by edit-terminal/edit-terminal.sh.
#
# Usage:
#   sudo ./edit-etc-default-useradd.sh                       # this system, or inside chroot
#   sudo ./edit-etc-default-useradd.sh <target etc/default/useradd>
#                                                            # e.g. <unpacked-root>/etc/default/useradd

set -e

# switch to script dir, so the relative useradd path always works
cd "$(dirname "$0")" || exit 1

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

if [ ! -f useradd ]; then
    echo "useradd not found, exiting" >&2
    exit 1
fi

# An empty or comment-only file would wipe the defaults instead of replacing
# them, so verify the payload actually pins the shell before copying it.
shell=$(sed -n 's/^SHELL=//p' useradd | tail -n 1)
case "$shell" in
/bin/zsh) ;;
*)
    echo "SHELL=/bin/zsh missing from useradd, refusing to overwrite the target" >&2
    exit 1
    ;;
esac

# Target: prefer the argument, otherwise write to the running system / chroot.
if [ -n "${1:-}" ]; then
    target=$1
else
    target=/etc/default/useradd
fi

dir=$(dirname "$target")
mkdir -p "$dir" || {
    echo "mkdir fail error!" >&2
    exit 1
}

# Keep /etc/default/useradd itself: mode 0644 and root:root, no execute bit.
cp -f useradd "$target" || {
    echo "copy fail error!" >&2
    exit 1
}
chmod 0644 "$target" || {
    echo "chmod fail error!" >&2
    exit 1
}

# cp -f onto an unwritable target can leave the old content behind, so read it
# back: never report a success the caller did not actually get.
if [ "$(sed -n 's/^SHELL=//p' "$target" | tail -n 1)" != "/bin/zsh" ]; then
    echo "replace $target did not take effect, exiting" >&2
    exit 1
fi

echo "Done! Edit /etc/default/useradd OK! -> $target (SHELL=$shell)"
