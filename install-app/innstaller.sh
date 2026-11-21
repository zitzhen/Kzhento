#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# App-URL: https://github.com/zitzhen/kzhento-installer-prompt
# OS-repository: https://github.com/zitzhen/kzhento-installer-prompt
# SPDX-License-Identifier: AGPL-3.0-only

set -e

# Locate dependent scripts by the script's own directory, so they are still found
# when the caller's cwd is not this directory.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Dependent projects
sh "$SCRIPT_DIR/curl.sh"

export DEBIAN_FRONTEND=noninteractive

# Install a fixed published release artifact only: no source checkout, no build,
# no floating "latest" tag. Bump VERSION together with the upstream release.
VERSION="1.0.4"
BASE_URL="https://github.com/zitzhen/kzhento-installer-prompt/releases/download/v${VERSION}"
DEB_FILE="kzhento-installer-prompt_${VERSION}_amd64.deb"
CHECKSUMS="SHA256SUMS"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

curl -fL -o "$WORK_DIR/$DEB_FILE" "$BASE_URL/$DEB_FILE"
curl -fL -o "$WORK_DIR/$CHECKSUMS" "$BASE_URL/$CHECKSUMS"

# Only verify the line for our artifact; extra entries in SHA256SUMS are not
# downloaded and must not make this check fail.
(cd "$WORK_DIR" && awk -v f="$DEB_FILE" '$2 == f' "$CHECKSUMS" | sha256sum -c -)

# apt resolves the Qt6/KF6 dependencies; the package's Replaces/Breaks metadata
# removes the old kubuntu-installer-prompt automatically.
apt-get install -y "$WORK_DIR/$DEB_FILE"
