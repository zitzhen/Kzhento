#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for build.sh's sync of the rebuilt initramfs into casper/.
#
# The boot screen is drawn by the initramfs GRUB loads, and that file lives
# outside the squashfs: /casper/initrd. update-initramfs only writes
# /boot/initrd.img-<kver> inside the layer, so a build that repacks the layer
# without copying the initramfs out still passes every in-layer branding check
# while the ISO keeps booting the base ISO's stock artwork. That is exactly how
# the branded 0.1.0 release shipped with the Kubuntu logo, so the copy is
# tested here rather than only asserted after a 15-minute ISO build.
#
# build.sh is not sourced (it runs main on load); the function is extracted by
# name so the test cannot drift from the implementation.
#
# Usage: bash tests/casper-boot-sync.test.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$REPO_DIR/build.sh"

[ -f "$BUILD" ] || {
    printf 'XX  missing %s\n' "$BUILD" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

# Extract sync_casper_boot() from build.sh verbatim, so the fixture drives the
# real implementation instead of a copy that can rot.
extract_fn() {
    awk '
        /^sync_casper_boot\(\) \{/ { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$BUILD"
}

fn_body=$(extract_fn)
[ -n "$fn_body" ] || fail "build.sh has no sync_casper_boot() function"

# run_sync <root> <iso-dir>: source the extracted function with the two globals
# it reads and call it. die/warn/log are the same helpers build.sh defines.
run_sync() {
    (
        set -euo pipefail
        # Read by the extracted function below, not by this script body.
        # shellcheck disable=SC2034
        ROOT_DIR=$1
        # shellcheck disable=SC2034
        ISO_DIR=$2
        die() {
            printf 'XX  %s\n' "$*" >&2
            exit 1
        }
        warn() { printf '!!  %s\n' "$*" >&2; }
        log() { printf '==> %s\n' "$*"; }
        eval "$fn_body"
        sync_casper_boot
    )
}

# make_tree <dir>: an unpacked image with a versioned kernel and initramfs, plus
# an ISO tree whose casper/ still holds the base ISO's older files.
make_tree() {
    local base=$1
    rm -rf "$base"
    mkdir -p "$base/root/boot" "$base/root/etc/initramfs-tools" "$base/iso/casper"
    printf 'kernel-image' >"$base/root/boot/vmlinuz-7.0.0-30-generic"
    ln -s vmlinuz-7.0.0-30-generic "$base/root/boot/vmlinuz"
    printf 'rebuilt-initramfs' >"$base/root/boot/initrd.img-7.0.0-30-generic"
    : >"$base/root/etc/initramfs-tools/initramfs.conf"
    printf 'base-kernel' >"$base/iso/casper/vmlinuz"
    printf 'base-initramfs' >"$base/iso/casper/initrd"
}

# --- the rebuilt initramfs replaces the base ISO's -----------------------
make_tree "$TMP/sync"
run_sync "$TMP/sync/root" "$TMP/sync/iso" >/dev/null
got=$(cat "$TMP/sync/iso/casper/initrd")
[ "$got" = "rebuilt-initramfs" ] ||
    fail "casper/initrd was not replaced (got '$got')"
ok "the rebuilt initramfs is copied to casper/initrd"

got=$(cat "$TMP/sync/iso/casper/vmlinuz")
[ "$got" = "kernel-image" ] ||
    fail "casper/vmlinuz was not synced with the layer's kernel (got '$got')"
ok "casper/vmlinuz is synced with the kernel the initramfs was built for"

# No temporary file may be left behind next to the result.
if ls "$TMP/sync/iso/casper"/*.tmp >/dev/null 2>&1; then
    fail "a .tmp file was left in casper/: $(ls "$TMP/sync/iso/casper")"
fi
ok "no temporary file is left in casper/"

# --- an image without initramfs-tools is skipped, not failed ------------
make_tree "$TMP/skip"
rm -f "$TMP/skip/root/etc/initramfs-tools/initramfs.conf"
out=$(run_sync "$TMP/skip/root" "$TMP/skip/iso" 2>&1) || fail "a tree without initramfs-tools failed: $out"
case "$out" in *'skipping the casper/ boot file sync'*) ;; *) fail "no diagnostic for a missing initramfs-tools: $out" ;; esac
got=$(cat "$TMP/skip/iso/casper/initrd")
[ "$got" = "base-initramfs" ] || fail "casper/initrd was touched without initramfs-tools (got '$got')"
ok "an image without initramfs-tools is skipped"

# --- an image with no rebuilt initramfs is skipped, not failed ----------
make_tree "$TMP/nothing"
rm -f "$TMP/nothing/root/boot/initrd.img-7.0.0-30-generic"
out=$(run_sync "$TMP/nothing/root" "$TMP/nothing/iso" 2>&1) || fail "a tree without a rebuilt initramfs failed: $out"
case "$out" in *'skipping the casper/ boot file sync'*) ;; *) fail "no diagnostic for a missing initramfs: $out" ;; esac
got=$(cat "$TMP/nothing/iso/casper/initrd")
[ "$got" = "base-initramfs" ] || fail "casper/initrd was touched without a rebuilt initramfs (got '$got')"
ok "an image with no rebuilt initramfs is skipped"

# --- the sync runs before the layer is repacked -------------------------
# Ordering is the whole point: after rm -rf of the root tree the initramfs is
# gone, so the copy has to happen while the layer still exists.
awk '
    /^[[:space:]]*apply_plymouth_theme[[:space:]]*$/ { theme = NR }
    /^[[:space:]]*sync_casper_boot[[:space:]]*$/   { sync = NR }
    /^[[:space:]]*mksquashfs[[:space:]]/           { first_mksquashfs = first_mksquashfs ? first_mksquashfs : NR }
    END {
        if (!theme || !sync || !first_mksquashfs) exit 1
        if (!(theme < sync && sync < first_mksquashfs)) exit 2
    }
' "$BUILD" || fail "sync_casper_boot is not called between apply_plymouth_theme and mksquashfs"
ok "the sync runs after the initramfs rebuild and before the repack"

printf '\nAll casper boot sync checks passed\n'
