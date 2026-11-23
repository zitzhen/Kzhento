#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Audit the branded surfaces of a release ISO without booting it.
#
# verify-artifact.sh is the build gate: it runs in the same job that produced
# the image, so it only ever sees a fresh build. This script answers the other
# question - "what does the ISO we are about to ship actually show?" - and it
# works on a download, long after the build tree is gone. Every surface that
# build.sh brands is reported as branded or stock, so a release cut from a
# checkout that predates a branding step is caught before it is published.
#
# Usage:
#   bash tests/release-iso-probe.sh <iso>
#   bash tests/release-iso-probe.sh <dir>     # dir holding filesystem.squashfs
#                                             # (or casper/) and initrd
#
# Environment:
#   KEEP_WORK  1 to keep the extracted layer and initramfs for inspection
#
# The image layer has to be unpacked from the ISO to be searched, so the work
# directory needs about 6G. Nothing here needs root, and the ISO is only read.

set -euo pipefail

TARGET=${1:-}
[ -n "$TARGET" ] || {
    printf 'Usage: bash tests/release-iso-probe.sh <iso | extracted dir>\n' >&2
    exit 2
}
[ -e "$TARGET" ] || {
    printf 'XX  not found: %s\n' "$TARGET" >&2
    exit 2
}

for c in unsquashfs awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || {
        printf 'XX  missing command: %s\n' "$c" >&2
        exit 2
    }
done

WORK=$(mktemp -d)
cleanup() {
    if [ "${KEEP_WORK:-0}" = "1" ]; then
        printf '\n..  kept extracted files in %s\n' "$WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

fail=0
branded() { printf 'ok  %s\n' "$*"; }
stock() {
    printf 'XX  %s\n' "$*"
    fail=$((fail + 1))
}
note() { printf '..  %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Locate the image layer and the initramfs: either in an already-extracted
# directory, or inside the ISO.
# ---------------------------------------------------------------------------
if [ -d "$TARGET" ]; then
    SFS=""
    for candidate in "$TARGET/filesystem.squashfs" "$TARGET/casper/filesystem.squashfs"; do
        [ -f "$candidate" ] && SFS=$candidate && break
    done
    [ -n "$SFS" ] || {
        printf 'XX  no filesystem.squashfs under %s\n' "$TARGET" >&2
        exit 2
    }
    INITRD="$TARGET/initrd"
    [ -f "$INITRD" ] || INITRD="$TARGET/casper/initrd"
    [ -f "$INITRD" ] || {
        printf 'XX  no casper/initrd under %s\n' "$TARGET" >&2
        exit 2
    }
else
    command -v xorriso >/dev/null 2>&1 || {
        printf 'XX  xorriso is needed to read an ISO\n' >&2
        exit 2
    }
    ISO=$TARGET
    note "extracting the image layer from $(basename "$ISO")"

    # Layered ISOs name the default layer in casper/install-sources.yaml; the
    # classic layout has one casper/filesystem.squashfs.
    layer=filesystem.squashfs
    if xorriso -osirrox on -indev "$ISO" -extract /casper/install-sources.yaml \
        "$WORK/install-sources.yaml" >/dev/null 2>&1 && [ -s "$WORK/install-sources.yaml" ]; then
        layer=$(awk '
            /^- default: true/  { def = 1; next }
            /^- default: false/ { def = 0; next }
            def && /^  path: /  { sub(/^  path: /, ""); print; exit }
        ' "$WORK/install-sources.yaml")
        [ -n "$layer" ] || {
            printf 'XX  cannot read the default layer from casper/install-sources.yaml\n' >&2
            exit 2
        }
    fi

    xorriso -osirrox on:auto_chmod_on -indev "$ISO" \
        -extract "/casper/$layer" "$WORK/$layer" >/dev/null 2>&1 || {
        printf 'XX  cannot extract /casper/%s from the ISO\n' "$layer" >&2
        exit 2
    }
    xorriso -osirrox on:auto_chmod_on -indev "$ISO" \
        -extract /casper/initrd "$WORK/initrd" >/dev/null 2>&1 || {
        printf 'XX  cannot extract /casper/initrd from the ISO\n' >&2
        exit 2
    }
    SFS="$WORK/$layer"
    INITRD="$WORK/initrd"
fi

image() { unsquashfs -cat "$SFS" "$1" 2>/dev/null; }

# Listing one path also prints its leading directories, so the mode and target
# of an entry are read from the line whose name is exactly that path.
entry() {
    unsquashfs -lls "$SFS" "$1" 2>/dev/null |
        sed -n 's/^\([^ ]*\) [^ ]* *[0-9]* [0-9-]* [0-9:]* squashfs-root\(.*\)$/\1 \2/p' |
        awk -v p="/${1#/}" '$2 == p { print; exit }'
}

# -cat follows symlinks and fails on directories, which is enough to tell an
# installed file from a missing one.
present() { unsquashfs -cat "$SFS" "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Boot splash: the theme is only on screen once it is baked into the initramfs,
# so the initramfs is what gets checked, not just the image's theme directory.
# ---------------------------------------------------------------------------
printf '== boot splash (initramfs + image)\n'

INITRD_DIR="$WORK/initramfs"
mkdir -p "$INITRD_DIR"
if command -v unmkinitramfs >/dev/null 2>&1; then
    unmkinitramfs "$INITRD" "$INITRD_DIR" >/dev/null 2>&1 || true
else
    (cd "$INITRD_DIR" && zstd -dc "$INITRD" | cpio -idm --quiet) >/dev/null 2>&1 || true
fi
# unmkinitramfs puts the main archive in main/ on some versions and at the top
# on others; the plymouth themes are in whichever directory has them.
for nested in "$INITRD_DIR" "$INITRD_DIR"/main "$INITRD_DIR"/*/; do
    [ -d "$nested/usr/share/plymouth" ] && INITRD_DIR=${nested%/} && break
done

if [ -d "$INITRD_DIR/usr/share/plymouth/themes/minimal" ]; then
    branded "initramfs carries the Kzhento theme"
else
    stock "initramfs has no Kzhento theme (boot still draws a stock one)"
fi

if present usr/share/plymouth/themes/minimal/minimal.plymouth; then
    branded "image carries /usr/share/plymouth/themes/minimal"
else
    stock "image has no /usr/share/plymouth/themes/minimal"
fi

alt=$(entry etc/alternatives/default.plymouth)
case "$alt" in
*'->'*minimal*) branded "default.plymouth -> Kzhento theme (${alt##*-> })" ;;
*'->'*) stock "default.plymouth -> ${alt##*-> }" ;;
*) stock "default.plymouth is missing or not a symlink" ;;
esac

# The stock spinner theme's watermark.png is a dpkg symlink into
# /usr/share/pixmaps; a stock image keeps it, a branded one replaces it.
mode=$(entry usr/share/plymouth/themes/spinner/watermark.png | awk '{ print $1 }')
case "$mode" in
-*) branded "spinner/watermark.png is a regular file" ;;
l*) stock "spinner/watermark.png is still the dpkg symlink into /usr/share/pixmaps" ;;
*) note "spinner/watermark.png not listed (theme may be absent)" ;;
esac

# ---------------------------------------------------------------------------
# The other branded surfaces, each written by its own build step.
# ---------------------------------------------------------------------------
printf '== wordmark, welcome center, about page, login shell\n'

if present usr/share/pixmaps/ubuntu-logo-text-dark.png.zhento-orig; then
    branded "/usr/share/pixmaps wordmark replaced (upstream kept as .zhento-orig)"
else
    stock "/usr/share/pixmaps wordmark not replaced (no .zhento-orig backup)"
fi

if present usr/share/backgrounds/kzhento/kzhento.png; then
    branded "Kzhento logo installed under /usr/share/backgrounds/kzhento"
else
    stock "/usr/share/backgrounds/kzhento is missing"
fi

for lang in en zh_CN; do
    if image "/usr/share/locale/$lang/LC_MESSAGES/kubuntu-notification-helper.mo" |
        LC_ALL=C grep -aq 'K-Zhento'; then
        branded "welcome center catalogue branded: $lang"
    else
        stock "welcome center catalogue not branded: $lang"
    fi
done

about=$(image /etc/xdg/kcm-about-distrorc || true)
if printf '%s\n' "$about" | grep -qx 'Name=K-Zhento'; then
    branded "about page name is K-Zhento"
else
    stock "about page name is not K-Zhento"
fi
if printf '%s\n' "$about" | grep -qx 'LogoPath=start-here-kde'; then
    branded "about page logo is start-here-kde"
else
    stock "about page logo is not start-here-kde"
fi

osrel=$(image /etc/os-release || true)
logo=$(printf '%s\n' "$osrel" | sed -n 's/^LOGO=//p')
if [ "$logo" = "start-here-kde" ]; then
    branded "/etc/os-release LOGO=start-here-kde"
else
    stock "/etc/os-release LOGO=${logo:-<unset>}"
fi

root_shell=$(image /etc/passwd 2>/dev/null | awk -F: '$3 == 0 { print $7 }' || true)
if [ "$root_shell" = "/bin/zsh" ]; then
    branded "root login shell is /bin/zsh"
else
    stock "root login shell is ${root_shell:-<unknown>}"
fi

if image /etc/default/useradd | grep -qx 'SHELL=/bin/zsh'; then
    branded "/etc/default/useradd gives new accounts /bin/zsh"
else
    stock "/etc/default/useradd does not default to /bin/zsh"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'All branded surfaces are in place.\n'
    exit 0
fi
printf '%d branded surface(s) still carry stock artwork:\n' "$fail"
printf 'the ISO was cut from a checkout that predates those branding steps;\n'
printf 'rebuild with build.sh to pick them up.\n'
exit 1
