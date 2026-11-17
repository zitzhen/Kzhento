#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Smoke test: the product version must be identical in the build script,
# the in-ISO os-release and the build workflow. The Ubuntu base version in
# os-release must also match the base ISO (26.04.1).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_SH="$REPO_DIR/build.sh"
OS_RELEASE="$REPO_DIR/edit-os-release/os-release"
WORKFLOW="$REPO_DIR/.github/workflows/build-iso.yml"

fail() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}

for f in "$BUILD_SH" "$OS_RELEASE" "$WORKFLOW"; do
    [ -f "$f" ] || fail "Missing file: $f"
done

build_v=$(sed -n 's/^VERSION=${VERSION:-\([^}]*\)}$/\1/p' "$BUILD_SH")
os_v=$(sed -n 's/^VERSION_ID="\([^"]*\)"$/\1/p' "$OS_RELEASE")
wf_v=$(awk '
    /^  workflow_dispatch:/ { wd = 1 }
    wd && /^      version:/  { ver = 1 }
    ver && /default:/ {
        if (match($0, /"[^"]*"/)) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
    }
' "$WORKFLOW")
pretty_v=$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$OS_RELEASE")
codename=$(sed -n 's/^VERSION_CODENAME=\(.*\)$/\1/p' "$OS_RELEASE")
ubuntu_codename=$(sed -n 's/^UBUNTU_CODENAME=\(.*\)$/\1/p' "$OS_RELEASE")

[ -n "$build_v" ] || fail "Cannot read VERSION from build.sh"
[ -n "$os_v" ] || fail "Cannot read VERSION_ID from os-release"
[ -n "$wf_v" ] || fail "Cannot read inputs.version.default from build-iso.yml"

printf 'build.sh VERSION           : %s\n' "$build_v"
printf 'os-release VERSION_ID      : %s\n' "$os_v"
printf 'build-iso.yml default      : %s\n' "$wf_v"
printf 'os-release VERSION         : %s\n' "$pretty_v"

[ "$build_v" = "$os_v" ] || fail "Version drift: build.sh=$build_v os-release=$os_v"
[ "$build_v" = "$wf_v" ] || fail "Version drift: build.sh=$build_v workflow=$wf_v"

case "$pretty_v" in
*26.04*) ;;
*) fail "os-release VERSION must describe the 26.04 base ISO, got: $pretty_v" ;;
esac

[ -n "$codename" ] && [ "$codename" = "$ubuntu_codename" ] ||
    fail "Codename mismatch: VERSION_CODENAME=$codename UBUNTU_CODENAME=$ubuntu_codename"

printf 'OK  version consistency (%s), base 26.04.1, codename %s\n' "$build_v" "$codename"
