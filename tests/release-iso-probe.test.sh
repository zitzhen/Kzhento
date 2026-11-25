#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for tests/release-iso-probe.sh.
#
# The probe is the only thing that reports what a shipped ISO shows, so its two
# answers matter equally: a branded image must come out clean, and a stock one
# must be reported surface by surface. Both are checked against a fixture built
# here, because the real image is 5G and cannot live in CI. The fixture also
# pins the two things the probe gets wrong most easily: reading an entry's mode
# from a listing that starts with directories (which made a regular file look
# like a symlink), and expecting the Kzhento theme in the image when it is the
# initramfs that actually draws the boot screen.
#
# Usage: bash tests/release-iso-probe.test.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROBE="$REPO_DIR/tests/release-iso-probe.sh"

for c in mksquashfs cpio gzip unsquashfs awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || {
        printf 'skip - missing command: %s\n' "$c" >&2
        exit 0
    }
done
[ -f "$PROBE" ] || {
    printf 'XX  missing probe: %s\n' "$PROBE" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

# make_image <dir> <stock|branded>: a root tree holding every surface the probe
# looks at. The stock variant keeps the upstream artwork, the branded one has
# each step's output.
make_image() {
    local root=$1 kind=$2
    rm -rf "$root"
    mkdir -p "$root"/usr/share/plymouth/themes/{spinner,minimal} \
        "$root"/usr/share/pixmaps \
        "$root"/usr/share/locale/en/LC_MESSAGES \
        "$root"/usr/share/locale/zh_CN/LC_MESSAGES \
        "$root"/etc/alternatives "$root"/etc/xdg "$root"/etc/default "$root"/etc
    # A PNG header is enough: the probe asks which file is there, not what it
    # draws.
    printf '\211PNG\r\n\032\n' >"$root/usr/share/plymouth/themes/spinner/throbber-0001.png"
    printf '\211PNG\r\n\032\n' >"$root/usr/share/pixmaps/ubuntu-logo-text-dark.png"
    printf 'root:x:0:0:root:/root:%s\n' "$([ "$kind" = branded ] && echo /bin/zsh || echo /bin/bash)" \
        >"$root/etc/passwd"
    printf 'SHELL=%s\n' "$([ "$kind" = branded ] && echo /bin/zsh || echo /bin/sh)" \
        >"$root/etc/default/useradd"

    if [ "$kind" = branded ]; then
        mkdir -p "$root/usr/share/plymouth/themes/minimal"
        printf '[Plymouth Theme]\nName=Kzhento\n' \
            >"$root/usr/share/plymouth/themes/minimal/minimal.plymouth"
        # The stock watermark is a symlink; the probe has to see a regular file
        # here even though the listing also prints the leading directories.
        printf '\211PNG\r\n\032\n' >"$root/usr/share/plymouth/themes/spinner/watermark.png"
        printf '\211PNG\r\n\032\n' >"$root/usr/share/pixmaps/ubuntu-logo-text-dark.png.zhento-orig"
        mkdir -p "$root/usr/share/backgrounds/kzhento"
        printf '\211PNG\r\n\032\n' >"$root/usr/share/backgrounds/kzhento/kzhento.png"
        for lang in en zh_CN; do
            printf 'K-Zhento' >"$root/usr/share/locale/$lang/LC_MESSAGES/kubuntu-notification-helper.mo"
        done
        printf '[General]\nName=K-Zhento\nLogoPath=start-here-kde\n' >"$root/etc/xdg/kcm-about-distrorc"
        printf 'PRETTY_NAME="KzhenTo 0.1.0"\nLOGO=start-here-kde\n' >"$root/etc/os-release"
        mkdir -p "$root/usr/share/icons/hicolor/128x128/places" \
            "$root/usr/share/icons/breeze/places/64"
        printf '\211PNG\r\n\032\n' >"$root/usr/share/icons/hicolor/128x128/places/start-here-kde.png"
        printf '\211PNG\r\n\032\n' >"$root/usr/share/icons/breeze/places/64/start-here-kde.png"
        printf '<svg/>' >"$root/usr/share/icons/breeze/places/64/start-here-kde.svg.zhento-orig"
        ln -s ../usr/share/plymouth/themes/minimal/minimal.plymouth \
            "$root/etc/alternatives/default.plymouth"
    else
        ln -s ../../../pixmaps/ubuntu-logo-text-dark.png \
            "$root/usr/share/plymouth/themes/spinner/watermark.png"
        for lang in en zh_CN; do
            printf 'Kubuntu' >"$root/usr/share/locale/$lang/LC_MESSAGES/kubuntu-notification-helper.mo"
        done
        printf '[General]\nName=Kubuntu\nLogoPath=/usr/share/plasma/avatars/kubuntu-bug.png\n' \
            >"$root/etc/xdg/kcm-about-distrorc"
        printf 'PRETTY_NAME="Kubuntu 26.04.1 LTS"\nLOGO=ubuntu-logo\n' >"$root/etc/os-release"
        # The stock image names the icon but does not install it: the KDE
        # artwork lives in the theme as an SVG.
        mkdir -p "$root/usr/share/icons/breeze/places/64"
        printf '<svg/>' >"$root/usr/share/icons/breeze/places/64/start-here-kde.svg"
        ln -s /usr/share/plymouth/themes/kubuntu-logo/kubuntu-logo.plymouth \
            "$root/etc/alternatives/default.plymouth"
    fi
}

# make_initrd <dir> <stock|branded>: only the plymouth theme is relevant, and
# it is what proves the boot screen was rebuilt rather than just installed.
make_initrd() {
    local out=$1 kind=$2 stage="$TMP/stage-initrd-$3"
    rm -rf "$stage"
    mkdir -p "$stage/usr/share/plymouth/themes/kubuntu-logo"
    printf '[Plymouth Theme]\nName=Kubuntu Logo\n' \
        >"$stage/usr/share/plymouth/themes/kubuntu-logo/kubuntu-logo.plymouth"
    if [ "$kind" = branded ]; then
        mkdir -p "$stage/usr/share/plymouth/themes/minimal"
        printf '[Plymouth Theme]\nName=Kzhento\n' \
            >"$stage/usr/share/plymouth/themes/minimal/minimal.plymouth"
    fi
    (cd "$stage" && find . | cpio -o -H newc --quiet | gzip -9) >"$out"
}

# package <dir>: a fixture directory the probe accepts, holding the layer and
# the initramfs next to each other.
package() {
    local dir=$1 kind=$2
    rm -rf "$dir"
    mkdir -p "$dir"
    make_image "$TMP/root-$kind" "$kind"
    mksquashfs "$TMP/root-$kind" "$dir/filesystem.squashfs" \
        -noappend -no-progress -quiet -comp gzip >/dev/null
    make_initrd "$dir/initrd" "$kind" "$kind"
}

# --- branded image: nothing to report ------------------------------------
package "$TMP/branded" branded
if out=$(bash "$PROBE" "$TMP/branded" 2>&1); then
    ok "a branded image passes"
else
    printf '%s\n' "$out" >&2
    fail "a branded image was reported as stock"
fi
case "$out" in
*"spinner/watermark.png is a regular file"*) ok "a regular-file watermark is not mistaken for a symlink" ;;
*) printf '%s\n' "$out" >&2 && fail "the watermark check did not read the regular file" ;;
esac

# --- stock image: every surface reported, non-zero exit ------------------
package "$TMP/stock" stock
status=0
out=$(bash "$PROBE" "$TMP/stock" 2>&1) || status=$?
[ "$status" -ne 0 ] || {
    printf '%s\n' "$out" >&2
    fail "a stock image exited 0"
}
ok "a stock image exits non-zero"

for expected in \
    "initramfs has no Kzhento theme" \
    "image has no /usr/share/plymouth/themes/minimal" \
    "default.plymouth -> /usr/share/plymouth/themes/kubuntu-logo/kubuntu-logo.plymouth" \
    "spinner/watermark.png is still the dpkg symlink" \
    "wordmark not replaced" \
    "/usr/share/backgrounds/kzhento is missing" \
    "welcome center catalogue not branded: en" \
    "welcome center catalogue not branded: zh_CN" \
    "about page name is not K-Zhento" \
    "about page icon missing: no hicolor 128x128/places/start-here-kde.png" \
    "breeze still ships the stock start-here-kde.svg next to the Kzhento PNG" \
    "/etc/os-release LOGO=ubuntu-logo" \
    "root login shell is /bin/bash" \
    "/etc/default/useradd does not default to /bin/zsh"; do
    case "$out" in
    *"$expected"*) ;;
    *)
        printf '%s\n' "$out" >&2
        fail "the stock image did not report: $expected"
        ;;
    esac
done
ok "every stock surface is named in the report"

# --- initramfs is what decides the boot screen --------------------------
# A theme in the image without one in the initramfs still boots stock artwork,
# which is the exact state a half-finished build leaves behind.
package "$TMP/half" branded
make_initrd "$TMP/half/initrd" stock half
status=0
out=$(bash "$PROBE" "$TMP/half" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "an image whose initramfs was never rebuilt exited 0"
case "$out" in
*"initramfs has no Kzhento theme"*) ok "a theme that never reached the initramfs is reported" ;;
*)
    printf '%s\n' "$out" >&2
    fail "the initramfs check passed for stock artwork"
    ;;
esac

# --- usage --------------------------------------------------------------
status=0
bash "$PROBE" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "no argument did not exit 2"
status=0
bash "$PROBE" "$TMP/does-not-exist" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "a missing target did not exit 2"
ok "usage errors exit 2"

printf '\nAll release ISO probe checks passed\n'
