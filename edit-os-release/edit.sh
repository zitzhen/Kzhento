#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only

# switch to script dir, so the relative os-release path always works
cd "$(dirname "$0")" || exit 1

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

if [ ! -e /etc/os-release ]; then
    echo "/etc/os-release not found, exiting" >&2
    exit 1
fi

# follow the symlink: write to the real file /etc/os-release points to
if [ -L /etc/os-release ]; then
    target=$(readlink -f /etc/os-release) || {
        echo "readlink fail error!" >&2
        exit 1
    }
else
    target=/etc/os-release
fi

cp -f os-release "$target" || {
    echo "copy fail error!" >&2
    exit 1
}

echo "Done! Edit os-release OK!"
