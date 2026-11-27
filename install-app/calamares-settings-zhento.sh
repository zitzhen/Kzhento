#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only

set -e

# Locate dependent scripts by the script's own directory, so they are still
# found when the caller's cwd is not this directory.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Dependent projects
sh "$SCRIPT_DIR/curl.sh"

# Downloads are retried: this runs inside a long build, where a transient CDN
# failure should not throw the whole image away.
. "$SCRIPT_DIR/lib/zhento-fetch.sh"

# Install a fixed published release artifact only: no source checkout, no
# floating "latest" tag. Bump VERSION together with the upstream release.
VERSION="1.0.1"
BASE_URL="https://github.com/zitzhen/calamares-settings-zhento/releases/download/v${VERSION}"
DEB_FILE="calamares-settings-zhento_${VERSION}_all.deb"
CHECKSUMS="SHA256SUMS"

# In the ISO build this script runs inside chroot, where "/" is the image root.
# The optional argument makes it testable against an unpacked tree.
TARGET_ROOT=${1:-/}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

zhento_fetch "$BASE_URL/$DEB_FILE" "$WORK_DIR/$DEB_FILE"
zhento_fetch "$BASE_URL/$CHECKSUMS" "$WORK_DIR/$CHECKSUMS"

# SHA256SUMS entries are relative to the release directory, i.e. "./<file>".
(cd "$WORK_DIR" && awk -v f="./$DEB_FILE" '$2 == f' "$CHECKSUMS" | sha256sum -c -)

dpkg-deb -x "$WORK_DIR/$DEB_FILE" "$WORK_DIR/unpacked"

# Do NOT register the package with dpkg: calamares-settings-zhento conflicts
# with calamares-settings-ubuntu-flavor, which calamares-settings-kubuntu
# provides, and kzhento-installer-prompt depends on that package by exact
# name. Installing it would break apt for every later script. The branding is
# pure config and artwork, so unpacking it into place is enough.
install -d "$TARGET_ROOT/etc/calamares/branding"
rm -rf "$TARGET_ROOT/etc/calamares/branding/kzhento"
cp -a "$WORK_DIR/unpacked/etc/calamares/branding/kzhento" \
    "$TARGET_ROOT/etc/calamares/branding/"
install -m 0644 "$WORK_DIR/unpacked/etc/calamares/settings.conf" \
    "$TARGET_ROOT/etc/calamares/settings.conf"
install -m 0644 "$WORK_DIR/unpacked/usr/share/applications/kubuntu-calamares.desktop" \
    "$TARGET_ROOT/usr/share/applications/kubuntu-calamares.desktop"
