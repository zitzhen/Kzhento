#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Fetch the Kzhento logo from zitzhen/kzhento-icon at build time and install
# it into the target system. The binary artwork is deliberately NOT committed
# to this repository; it is downloaded during the build instead.
#
# Usage:
#   sudo ./edit-logo.sh                 # install into the current system
#   sudo ./edit-logo.sh <target root>   # install into an unpacked ISO / chroot root
#
# To update the artwork, bump LOGO_REF and the two checksums below together.

set -e

die() {
	printf 'XX  %s\n' "$*" >&2
	exit 1
}
log() { printf '==> %s\n' "$*"; }

# Pinned commit keeps builds reproducible. Change these three values as a set
# when https://github.com/zitzhen/kzhento-icon is updated.
LOGO_REF=afcfbd5497a4e19b009468a9b3f349edcdba61a3
RAW_BASE=https://raw.githubusercontent.com/zitzhen/kzhento-icon/$LOGO_REF

# Only the PNGs are shipped in the image; the PSD is an editing source file.
FILES="kzhento.png kzhento_transparent.png"
SUMS="3abacbc0c3a21f3b5d27beb5a6bcf97d845e1a8cbefbeef70a152249a1b22399  kzhento.png
eba6a63c01475fe3286b88a1c5eede6a6ccddae1260996afbfc80d78415dfc1f  kzhento_transparent.png"

[ "$(id -u)" -eq 0 ] || die "root is required: sudo $0"

if command -v curl >/dev/null 2>&1; then
	fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
	fetch() { wget -q -O "$2" "$1"; }
else
	die "Need curl or wget to download the logo"
fi

target=${1:-/}
dest="$target/usr/share/backgrounds/kzhento"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for f in $FILES; do
	log "Downloading $f from kzhento-icon@$LOGO_REF"
	fetch "$RAW_BASE/$f" "$tmp/$f" || die "Failed to download $f"
	[ -s "$tmp/$f" ] || die "Downloaded $f is empty"
done

printf '%s\n' "$SUMS" | (cd "$tmp" && sha256sum -c -) ||
	die "Logo checksum verification failed"

log "Installing logo to $dest"
install -d -m 0755 "$dest"
for f in $FILES; do
	install -m 0644 "$tmp/$f" "$dest/$f"
done

log "Done: $dest/kzhento.png, $dest/kzhento_transparent.png"
