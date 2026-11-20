#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Best-effort VM boot smoke test for the UEFI-only ZhenTo ISO.
# Boots with QEMU + OVMF, captures the serial console, and checks that the
# firmware / GRUB / kernel start cleanly. The shipped GRUB entry uses
# "quiet splash" and does not enable a serial console, so a login prompt is
# not guaranteed: this layer is intentionally advisory, not a release gate.
#
# Usage: bash tests/vm-smoke.sh <iso> [timeout-seconds]
#        OVMF_CODE=/path/to/OVMF_CODE.fd bash tests/vm-smoke.sh <iso>

set -euo pipefail

ISO=${1:-}
TIMEOUT=${2:-240}

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok  %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }

[ -n "$ISO" ] || die "Usage: bash tests/vm-smoke.sh <iso> [timeout-seconds]"
[ -f "$ISO" ] || die "ISO not found: $ISO"
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found"

OVMF_CODE=${OVMF_CODE:-}
if [ -z "$OVMF_CODE" ]; then
    for candidate in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        [ -f "$candidate" ] && OVMF_CODE=$candidate && break
    done
fi
[ -n "$OVMF_CODE" ] && [ -f "$OVMF_CODE" ] || die "OVMF firmware not found (set OVMF_CODE=...)"

TMP=$(mktemp -d)
PID_FILE="$TMP/qemu.pid"
LOG="$TMP/serial.log"
cleanup() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
: >"$LOG"

printf '..  booting %s with %s (timeout %ss)\n' "$ISO" "$OVMF_CODE" "$TIMEOUT"
qemu-system-x86_64 \
    -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "file=$ISO,media=cdrom,readonly=on" \
    -boot order=d \
    -display none \
    -serial "file:$LOG" \
    -pidfile "$PID_FILE" \
    -no-reboot \
    >/dev/null 2>&1 &
qemu_pid=$!

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    if grep -qE 'Try or Install KzhenTo|Linux version|Welcome to|login:|KzhenTo' "$LOG" 2>/dev/null; then
        break
    fi
    kill -0 "$qemu_pid" >/dev/null 2>&1 || break
    sleep 1
    elapsed=$((elapsed + 1))
done

if kill -0 "$qemu_pid" >/dev/null 2>&1; then
    kill "$qemu_pid" >/dev/null 2>&1 || true
    wait "$qemu_pid" >/dev/null 2>&1 || true
fi

[ -s "$LOG" ] || die "Serial console produced no output; firmware/ISO may not boot at all"
ok "OVMF/serial console produced output after ${elapsed}s"

if grep -qiE 'kernel panic|out of memory|fatal exception|no bootable option' "$LOG"; then
    printf '%s\n' '--- serial log tail ---' >&2
    tail -n 40 "$LOG" >&2 || true
    die "Fatal boot failure detected in serial log"
fi
ok "no fatal boot failure in serial log"

if grep -qE 'Try or Install KzhenTo|Linux version|Welcome to|login:|KzhenTo' "$LOG"; then
    ok "boot reached a recognizable KzhenTo / Linux marker"
else
    warn "no recognizable boot marker; see advisory log below"
fi

if grep -qE 'login:|Welcome to' "$LOG"; then
    ok "boot reached a login prompt"
else
    warn "no login prompt in serial log (expected: GRUB uses quiet splash and no serial console)"
fi

printf '%s\n' '--- serial log tail ---'
tail -n 30 "$LOG" || true
printf '\nVM smoke finished (advisory). Full UI checks still need a manual run.\n'
