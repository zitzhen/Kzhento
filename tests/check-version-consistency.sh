#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Smoke test: the product version must be identical in the build script,
# the in-ISO os-release and the build workflow. The Ubuntu base version in
# os-release must also match the base ISO (26.04.1).
#
# The logo pin is checked the same way: edit-logo.sh and the preflight job in
# pr-check.yml both name the upstream commit and the transparent PNG's sha256,
# and a download that verifies in one place but not the other is a build that
# breaks only in CI.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_SH="$REPO_DIR/build.sh"
OS_RELEASE="$REPO_DIR/edit-os-release/os-release"
WORKFLOW="$REPO_DIR/.github/workflows/build-iso.yml"
LOGO_SH="$REPO_DIR/edit-logo.sh/edit-logo.sh"
PR_CHECK="$REPO_DIR/.github/workflows/pr-check.yml"

fail() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}

for f in "$BUILD_SH" "$OS_RELEASE" "$WORKFLOW" "$LOGO_SH" "$PR_CHECK"; do
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

# --- logo pin: edit-logo.sh and the preflight job must agree ---------------
script_ref=$(sed -n 's/^LOGO_REF=\([0-9a-f]*\)$/\1/p' "$LOGO_SH")
script_sum=$(sed -n 's/^\([0-9a-f]\{64\}\)  kzhento_transparent\.png"\?$/\1/p' "$LOGO_SH")
wf_ref=$(sed -n 's/^ *ref=\([0-9a-f]\{40\}\)$/\1/p' "$PR_CHECK")
wf_sum=$(sed -n 's/^ *sum=\([0-9a-f]\{64\}\)$/\1/p' "$PR_CHECK")

[ -n "$script_ref" ] && [ -n "$script_sum" ] ||
    fail "Cannot read LOGO_REF or the kzhento_transparent.png checksum from edit-logo.sh"
[ -n "$wf_ref" ] && [ -n "$wf_sum" ] ||
    fail "Cannot read the logo ref or checksum from pr-check.yml"

printf 'edit-logo.sh pin           : %s\n' "${script_ref:0:12}"
printf 'pr-check.yml pin           : %s\n' "${wf_ref:0:12}"

[ "$script_ref" = "$wf_ref" ] ||
    fail "Logo pin drift: edit-logo.sh=$script_ref pr-check.yml=$wf_ref"
[ "$script_sum" = "$wf_sum" ] ||
    fail "Logo checksum drift: edit-logo.sh=$script_sum pr-check.yml=$wf_sum"

printf 'OK  logo pin consistent (%s), sha256 %s\n' "${script_ref:0:12}" "${script_sum:0:12}"
