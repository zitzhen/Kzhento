#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for build.sh's sync of the rebuilt initramfs into casper/.
#
# Two separate bugs live here, and both are only visible after a full boot:
#
#   1. The initramfs GRUB loads lives outside the squashfs (/casper/initrd),
#      while update-initramfs writes /boot/initrd.img-<kver> inside the layer.
#      A build that repacks the layer without copying the file out passes every
#      in-layer branding check and still boots the base ISO's stock artwork.
#
#   2. A chroot rebuild drops the live-boot config. conf/uuid.conf and
#      conf/conf.d/default-boot-to-casper.conf are written by the casper
#      initramfs hook only when CASPER_GENERATE_UUID is set, which the stock
#      image build does and the rebuild does not. Without them init falls back
#      to BOOT=local, run-init has no root to switch to, and PID 1 dies with
#      "Attempted to kill init!" - a kernel panic (issue #21).
#
# Both were found by booting a real image, so both are pinned here on a fixture
# that mimics the stock archive: microcode segments in front of the root tree.
#
# build.sh is not sourced (it runs main on load); the functions are extracted by
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
for c in cpio python3; do
    command -v "$c" >/dev/null 2>&1 || {
        printf 'skip - missing command: %s\n' "$c" >&2
        exit 0
    }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

# Extract a function from build.sh verbatim.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$BUILD"
}

sync_body=$(extract_fn sync_casper_boot)
unpack_body=$(extract_fn unpack_initramfs)
repack_body=$(extract_fn repack_initramfs)
[ -n "$sync_body" ] || fail "build.sh has no sync_casper_boot() function"
[ -n "$unpack_body" ] || fail "build.sh has no unpack_initramfs() function"
[ -n "$repack_body" ] || fail "build.sh has no repack_initramfs() function"

UUID=11111111-2222-3333-4444-555555555555

# run_sync <root> <iso-dir>: drive the extracted functions.
run_sync() {
    (
        set -euo pipefail
        # Read by the extracted functions, not by this script body.
        # shellcheck disable=SC2034
        ROOT_DIR=$1
        # shellcheck disable=SC2034
        ISO_DIR=$2
        # shellcheck disable=SC2034
        WORK_DIR=$3
        die() {
            printf 'XX  %s\n' "$*" >&2
            exit 1
        }
        warn() { printf '!!  %s\n' "$*" >&2; }
        log() { printf '==> %s\n' "$*"; }
        eval "$unpack_body"
        eval "$repack_body"
        eval "$sync_body"
        sync_casper_boot
    )
}

# make_initramfs <file>: a two-segment archive shaped like the real one, with a
# microcode segment in front of the root tree. The microcode must survive, and
# a naive `cpio -id` loses the whole tree behind it.
make_initramfs() {
    local out=$1 stage="$TMP/stage.$RANDOM"
    mkdir -p "$stage/early/kernel/x86" "$stage/root"/{bin,conf/conf.d,scripts}
    printf 'microcode' >"$stage/early/kernel/x86/microcode.bin"
    printf '#!/bin/sh\n' >"$stage/root/init"
    printf 'casper-script' >"$stage/root/scripts/casper"
    printf 'stale-base-uuid\n' >"$stage/root/conf/uuid.conf"
    (cd "$stage/early" && find . | cpio -o -H newc --quiet) >"$out"
    (cd "$stage/root" && find . | cpio -o -H newc --quiet) >>"$out"
    rm -rf "$stage"
}

# tree_has <initrd> <path> [content]: unpack the archive (all segments) and
# report whether the path exists, optionally with the given content.
tree_has() {
    local initrd=$1 want=$2 content=${3:-} extract="$TMP/extract.$RANDOM"
    mkdir -p "$extract"
    python3 - "$initrd" "$extract" <<'PY' || return 1
import subprocess, sys

path, dest = sys.argv[1], sys.argv[2]
data = open(path, 'rb').read()
pos = 0
while pos < len(data):
    while pos < len(data) and data[pos] == 0:
        pos += 1
    if pos >= len(data):
        break
    magic = data[pos:pos + 4]
    if magic == b'\x28\xb5\x2f\xfd':
        raw = subprocess.run(['zstd', '-dc'], input=data[pos:],
                             capture_output=True).stdout
        break
    if magic[:2] == b'\x1f\x8b':
        raw = subprocess.run(['gzip', '-dc'], input=data[pos:],
                             capture_output=True).stdout
        break
    i = pos
    while i < len(data) and data[i:i + 6] in (b'070701', b'070702'):
        hdr = data[i:i + 110]
        nsize = int(hdr[94:102], 16)
        fsize = int(hdr[54:62], 16)
        name = data[i + 110:i + 110 + nsize - 1]
        i += 110 + nsize
        i = (i + 3) & ~3
        i += fsize
        i = (i + 3) & ~3
        if name == b'TRAILER!!!':
            break
    if i == pos:
        break
    subprocess.run(['cpio', '-idm', '--quiet', '-D', dest], input=data[pos:i],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pos = i
PY
    [ -e "$extract/$want" ] || return 1
    if [ -n "$content" ]; then
        [ "$(cat "$extract/$want")" = "$content" ] || return 1
    fi
    rm -rf "$extract"
    return 0
}

# make_tree <dir>: an unpacked image with a rebuilt initramfs, plus an ISO tree
# whose casper/ still holds the base ISO's older files.
make_tree() {
    local base=$1
    rm -rf "$base"
    mkdir -p "$base/root/boot" "$base/root/etc/initramfs-tools" \
        "$base/iso/casper" "$base/iso/.disk" "$base/work"
    printf 'kernel-image' >"$base/root/boot/vmlinuz-7.0.0-30-generic"
    ln -s vmlinuz-7.0.0-30-generic "$base/root/boot/vmlinuz"
    : >"$base/root/etc/initramfs-tools/initramfs.conf"
    make_initramfs "$base/root/boot/initrd.img-7.0.0-30-generic"
    printf 'base-kernel' >"$base/iso/casper/vmlinuz"
    make_initramfs "$base/iso/casper/initrd"
    printf '%s\n' "$UUID" >"$base/iso/.disk/casper-uuid-generic"
}

# --- the live-boot config is injected ------------------------------------
make_tree "$TMP/sync"
run_sync "$TMP/sync/root" "$TMP/sync/iso" "$TMP/sync/work" >/dev/null

tree_has "$TMP/sync/iso/casper/initrd" conf/conf.d/default-boot-to-casper.conf ||
    fail "casper/initrd has no conf/conf.d/default-boot-to-casper.conf: BOOT would fall back to local"
ok "casper/initrd carries the BOOT=casper config"

tree_has "$TMP/sync/iso/casper/initrd" conf/uuid.conf "$UUID" ||
    fail "conf/uuid.conf in casper/initrd is missing or is not the ISO's casper uuid"
ok "conf/uuid.conf matches the ISO's casper uuid"

# The microcode segment in front of the root tree has to survive: a `cpio -id`
# on the archive stops at its first TRAILER!!! and would drop everything behind.
tree_has "$TMP/sync/iso/casper/initrd" kernel/x86/microcode.bin microcode ||
    fail "the early microcode segment was lost while repacking"
ok "the early microcode segment survives the repack"

tree_has "$TMP/sync/iso/casper/initrd" scripts/casper casper-script ||
    fail "the root tree behind the microcode segment was lost"
ok "the root tree behind the microcode segment is intact"

got=$(cat "$TMP/sync/iso/casper/vmlinuz")
[ "$got" = "kernel-image" ] ||
    fail "casper/vmlinuz was not synced with the layer's kernel (got '$got')"
ok "casper/vmlinuz is synced with the kernel the initramfs was built for"

# The result must not be a plain copy of the rebuilt archive any more.
cmp -s "$TMP/sync/root/boot/initrd.img-7.0.0-30-generic" "$TMP/sync/iso/casper/initrd" &&
    fail "casper/initrd is a byte-for-byte copy of the rebuilt initramfs"
ok "casper/initrd differs from the rebuilt initramfs"

if ls "$TMP/sync/iso/casper"/*.tmp >/dev/null 2>&1; then
    fail "a .tmp file was left in casper/: $(ls "$TMP/sync/iso/casper")"
fi
ok "no temporary file is left in casper/"

# --- skips, not failures -------------------------------------------------
make_tree "$TMP/skip"
rm -f "$TMP/skip/root/etc/initramfs-tools/initramfs.conf"
out=$(run_sync "$TMP/skip/root" "$TMP/skip/iso" "$TMP/skip/work" 2>&1) || fail "a tree without initramfs-tools failed: $out"
case "$out" in *'skipping the casper/ boot file sync'*) ;; *) fail "no diagnostic for a missing initramfs-tools: $out" ;; esac
ok "an image without initramfs-tools is skipped"

make_tree "$TMP/nothing"
rm -f "$TMP/nothing/root/boot/initrd.img-7.0.0-30-generic"
out=$(run_sync "$TMP/nothing/root" "$TMP/nothing/iso" "$TMP/nothing/work" 2>&1) || fail "a tree without a rebuilt initramfs failed: $out"
case "$out" in *'skipping the casper/ boot file sync'*) ;; *) fail "no diagnostic for a missing initramfs: $out" ;; esac
ok "an image with no rebuilt initramfs is skipped"

# --- ordering ------------------------------------------------------------
# After the repack the root tree is deleted, so the sync has to happen before it.
awk '
    /^[[:space:]]*apply_plymouth_theme[[:space:]]*$/ { theme = NR }
    /^[[:space:]]*sync_casper_boot[[:space:]]*$/   { sync = NR }
    /^[[:space:]]*mksquashfs[[:space:]]/           { first = first ? first : NR }
    END {
        if (!theme || !sync || !first) exit 1
        if (!(theme < sync && sync < first)) exit 2
    }
' "$BUILD" || fail "sync_casper_boot is not called between apply_plymouth_theme and mksquashfs"
ok "the sync runs after the initramfs rebuild and before the repack"

printf '\nAll casper boot sync checks passed\n'
