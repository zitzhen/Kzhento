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

export DEBIAN_FRONTEND=noninteractive

# Install a fixed published release artifact only: no source checkout, no
# floating "latest" tag. Bump VERSION together with the upstream release.
VERSION="1.0.1"
BASE_URL="https://github.com/zitzhen/calamares-settings-zhento/releases/download/v${VERSION}"
DEB_FILES="calamares-settings-zhento-common-data_${VERSION}_all.deb
calamares-settings-zhento-common_${VERSION}_amd64.deb
calamares-settings-zhento_${VERSION}_all.deb"
CHECKSUMS="SHA256SUMS"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

for f in $DEB_FILES; do
    curl -fL -o "$WORK_DIR/$f" "$BASE_URL/$f"
done
curl -fL -o "$WORK_DIR/$CHECKSUMS" "$BASE_URL/$CHECKSUMS"

# SHA256SUMS entries are relative to the release directory, i.e. "./<file>".
# Verify only the artifacts we downloaded; extra entries are not downloaded.
for f in $DEB_FILES; do
    (cd "$WORK_DIR" && awk -v f="./$f" '$2 == f' "$CHECKSUMS" | sha256sum -c -)
done

# These packages own the same paths as calamares-settings-kubuntu and its
# common packages. Keep the Kubuntu packages in dpkg's database because
# kzhento-installer-prompt depends on calamares-settings-kubuntu by exact
# name, but let the Zhento branding files win. This makes Calamares read
# /etc/calamares/branding/kzhento/branding.desc and show KzhenTo branding.
dpkg -i --force-conflicts --force-overwrite \
    "$WORK_DIR/calamares-settings-zhento-common-data_${VERSION}_all.deb" \
    "$WORK_DIR/calamares-settings-zhento-common_${VERSION}_amd64.deb" \
    "$WORK_DIR/calamares-settings-zhento_${VERSION}_all.deb"
