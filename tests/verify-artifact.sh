#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Post-build smoke checks: verify the ISO is bootable-by-design and contains
# the expected branding / preinstalled tools, without booting it or unpacking
# the full 6.5G rootfs. Usage:
#   bash tests/verify-artifact.sh <iso> <version>

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
ISO=${1:-}
VERSION=${2:-}

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok  %s\n' "$*"; }

[ -n "$ISO" ] || die "Usage: bash tests/verify-artifact.sh <iso> <version>"
[ -n "$VERSION" ] || die "Usage: bash tests/verify-artifact.sh <iso> <version>"
[ -f "$ISO" ] || die "ISO not found: $ISO"

for c in xorriso unsquashfs md5sum sha256sum cmp awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. External checksum (produced by the build workflow), if present.
if [ -f "${ISO}.sha256" ]; then
    (cd "$(dirname "$ISO")" && sha256sum -c "$(basename "$ISO").sha256") ||
        die "ISO sha256 check failed"
    ok "ISO sha256 checksum"
else
    printf '..  no %s, skipping external checksum\n' "${ISO}.sha256"
fi

# 2. Volume label (same 32-char truncation rule as build.sh) and UEFI catalog.
LABEL="ZhenTo ${VERSION} amd64"
[ "${#LABEL}" -le 32 ] || LABEL=${LABEL:0:32}
actual_label=$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p')
[ "$actual_label" = "$LABEL" ] || die "Volume label mismatch: expected '$LABEL', got '$actual_label'"
ok "volume label: $actual_label"

torito=$(LC_ALL=C xorriso -indev "$ISO" -report_el_torito as_mkisofs 2>/dev/null)
case "$torito" in
*appended_partition_2* | *efi* | *EFI*) ;;
*) die "No UEFI/EFI boot entry found in El Torito report: $torito" ;;
esac
ok "UEFI boot catalog entry"

# 3. Extract only the small ISO-tree files needed for assertions.
extract_iso() {
    xorriso -osirrox on:auto_chmod_on -indev "$ISO" -extract "$1" "$2" >/dev/null 2>&1 ||
        die "Cannot extract $1 from ISO"
}
extract_iso /boot/grub/grub.cfg "$TMP/grub.cfg"
extract_iso /md5sum.txt "$TMP/md5sum.txt"

# 3a. Layered ISOs describe the default squashfs in casper/install-sources.yaml;
# Kubuntu 26.04.1 uses the classic single casper/filesystem.squashfs instead.
xorriso -osirrox on:auto_chmod_on -indev "$ISO" \
    -extract /casper/install-sources.yaml "$TMP/install-sources.yaml" >/dev/null 2>&1 || true
if [ -s "$TMP/install-sources.yaml" ]; then
    layer=$(awk '
        /^- default: true/  { def = 1; next }
        /^- default: false/ { def = 0; next }
        def && /^  path: /  { sub(/^  path: /, ""); print; exit }
    ' "$TMP/install-sources.yaml")
    [ -n "$layer" ] || die "Cannot find default layer in casper/install-sources.yaml"
    manifest_pairs=("casper/install-sources.yaml:$TMP/install-sources.yaml")
    ok "layered ISO: detected $layer from install-sources.yaml"
else
    layer="filesystem.squashfs"
    manifest_pairs=("casper/filesystem.squashfs:$TMP/filesystem.squashfs")
    ok "classic ISO: using casper/filesystem.squashfs"
fi
extract_iso "/casper/$layer" "$TMP/$layer"

# 4. GRUB menu must be the one shipped in this repository.
cmp -s "$TMP/grub.cfg" "$REPO_DIR/edit-grub/grub.cfg" ||
    die "boot/grub/grub.cfg differs from edit-grub/grub.cfg"
ok "GRUB menu matches repository config"

# 5. Rebuild hash for a few extracted files from the ISO's own manifest.
for pair in "boot/grub/grub.cfg:$TMP/grub.cfg" "${manifest_pairs[@]}"; do
    iso_path=${pair%%:*}
    local_file=${pair#*:}
    expected=$(awk -v p="./$iso_path" '$2 == p { print $1; exit }' "$TMP/md5sum.txt")
    [ -n "$expected" ] || die "md5sum.txt has no entry for ./$iso_path"
    actual=$(md5sum "$local_file" | awk '{print $1}')
    [ "$expected" = "$actual" ] || die "md5sum.txt mismatch for $iso_path: expected $expected, got $actual"
    ok "ISO md5sum.txt covers $iso_path"
done

# 6. Read the in-image os-release from the selected casper layer.
unsquashfs -cat "$TMP/$layer" /etc/os-release >"$TMP/os-release" 2>/dev/null ||
    die "Cannot read /etc/os-release from $layer"

cmp -s "$TMP/os-release" "$REPO_DIR/edit-os-release/os-release" ||
    die "/etc/os-release in ISO differs from edit-os-release/os-release"
image_version=$(sed -n 's/^VERSION_ID="\([^"]*\)"$/\1/p' "$TMP/os-release")
[ "$image_version" = "$VERSION" ] ||
    die "VERSION_ID in ISO is '$image_version', expected '$VERSION'"
ok "in-image os-release matches repository and version $VERSION"

# 7. Preinstalled tools and build-time residue. Use -cat as a cheap existence
#    probe: it succeeds for regular files and fails (rc=2) when absent.
for f in usr/bin/curl usr/bin/git usr/bin/zsh usr/bin/patchsplit \
    var/lib/snapd/seed/seed.yaml etc/systemd/system/zhento-install-snap.service; do
    unsquashfs -cat "$TMP/$layer" "/$f" >/dev/null 2>&1 ||
        die "Missing in image: /$f"
    ok "present in image: /$f"
done

for leftover in opt/zhento-build/build.sh usr/sbin/policy-rc.d; do
    if unsquashfs -cat "$TMP/$layer" "/$leftover" >/dev/null 2>&1; then
        die "Build residue found in image: /$leftover"
    fi
    ok "no build residue: /$leftover"
done

# 8. Login shell packaging: root and every regular account must end up on zsh,
#    before and after installation. Accounts are reported one per line so a
#    single offender (often just root) is not buried behind the others.
#    "nobody" (65534) is a system account and keeps its nologin shell.
unsquashfs -cat "$TMP/$layer" /etc/passwd >"$TMP/passwd" 2>/dev/null ||
    die "Cannot read /etc/passwd from $layer"
if ! awk -F: '
    NF != 7 { next }
    $3 == 65534 { next }
    $3 == 0 || $3 >= 1000 { n++; if ($7 != "/bin/zsh") { bad++; print "    " $1 " has " $7 } }
    END {
        if (n == 0) { print "    no account to check"; exit 1 }
        if (bad != 0) exit 1
    }
' "$TMP/passwd" >"$TMP/offenders" 2>&1; then
    cat "$TMP/offenders" >&2
    die "root or a regular account in the ISO does not use /bin/zsh"
fi
ok "root and every regular account use /bin/zsh"

unsquashfs -cat "$TMP/$layer" /etc/default/useradd >"$TMP/useradd" 2>/dev/null ||
    die "Missing in image: /etc/default/useradd"
grep -qx 'SHELL=/bin/zsh' "$TMP/useradd" ||
    die "/etc/default/useradd does not default new accounts to /bin/zsh"
ok "/etc/default/useradd gives new accounts /bin/zsh"

unsquashfs -cat "$TMP/$layer" /etc/skel/.zshrc >"$TMP/skel.zshrc" 2>/dev/null ||
    die "Missing in image: /etc/skel/.zshrc"
cmp -s "$TMP/skel.zshrc" "$REPO_DIR/edit-etc-default-useradd/.zshrc" ||
    die "/etc/skel/.zshrc in ISO differs from edit-etc-default-useradd/.zshrc"
ok "in-image /etc/skel/.zshrc matches the repository payload"

# 9. Branding surfaces that are not files under /etc: the boot splash, the
#    distro wordmark, the Welcome Center catalogues and the About page.
#
#    The artwork itself is generated from the logo at build time, so it is only
#    checked for being a PNG of the expected size; its content is the render's
#    business, and ../edit-plymouth/render.py is what is unit-checked.
unsquashfs -cat "$TMP/$layer" /usr/share/plymouth/themes/minimal/minimal.plymouth \
    >"$TMP/minimal.plymouth" 2>/dev/null ||
    die "Missing in image: /usr/share/plymouth/themes/minimal/minimal.plymouth"
grep -qx 'Name=Kzhento' "$TMP/minimal.plymouth" ||
    die "Boot theme is not named Kzhento"
grep -qx 'ImageDir=/usr/share/plymouth/themes/minimal' "$TMP/minimal.plymouth" ||
    die "Boot theme does not point its ImageDir at its own directory"
ok "boot theme installed: Kzhento (minimal)"

# The theme's own frames are animation-NN.png: the two-step module draws those,
# and edit-plymouth.sh installs the rendered mark under the name the theme file
# declares. throbber-*.png only exists in the stock "spinner" theme, whose own
# script consumes it, so it is checked there and nowhere else.
animation=$(sed -n 's/^AnimationFile=//p' "$TMP/minimal.plymouth")
case "$animation" in
animation-*.png) ;;
*) die "Boot theme does not declare an animation-NN.png frame: '${animation}'" ;;
esac
animation_dir=$(sed -n 's/^AnimationDir=//p' "$TMP/minimal.plymouth")
animation_dir=${animation_dir:-usr/share/plymouth/themes/minimal}
ok "boot theme declares its animation: $animation"

for f in usr/share/plymouth/themes/minimal/watermark.png \
    usr/share/plymouth/themes/spinner/watermark.png \
    usr/share/plymouth/themes/spinner/throbber-0001.png \
    "$animation_dir/$animation"; do
    unsquashfs -cat "$TMP/$layer" "/$f" >"$TMP/asset.png" 2>/dev/null ||
        die "Missing in image: /$f"
    [ "$(head -c 8 "$TMP/asset.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] ||
        die "Not a PNG: /$f"
    ok "present in image: /$f"
done

# The spinner watermark used to be a symlink to the Ubuntu wordmark; it must be
# a regular file now, or the boot screen follows whatever that pixmap becomes.
#
# Asking unsquashfs for one path still lists the leading directories of that
# path, so the entry has to be picked out by its exact name: the first line of
# the listing is a directory, not the file.
mode=$(unsquashfs -lls "$TMP/$layer" /usr/share/plymouth/themes/spinner/watermark.png 2>/dev/null |
    sed -n 's/^\([^ ]*\) [^ ]* *[0-9]* [0-9-]* [0-9:]* squashfs-root\(.*\)$/\1 \2/p' |
    awk '$2 == "/usr/share/plymouth/themes/spinner/watermark.png" { print $1; exit }')
case "$mode" in
-*) ok "spinner watermark.png is a regular file" ;;
l*) die "spinner watermark.png is still a symlink" ;;
"") die "spinner watermark.png is missing from the listing" ;;
*) die "spinner watermark.png is not a regular file (mode $mode)" ;;
esac

# /usr/share/pixmaps/ubuntu-logo-text-dark.png is replaced in place, with the
# upstream file kept next to it.
for f in usr/share/pixmaps/ubuntu-logo-text-dark.png \
    usr/share/pixmaps/ubuntu-logo-text-dark.png.zhento-orig; do
    unsquashfs -cat "$TMP/$layer" "/$f" >/dev/null 2>&1 ||
        die "Missing in image: /$f"
    ok "present in image: /$f"
done

# default.plymouth must resolve to the Kzhento theme, otherwise the theme is
# installed but never drawn.
applied=$(unsquashfs -cat "$TMP/$layer" /etc/alternatives/default.plymouth 2>/dev/null) ||
    die "Missing in image: /etc/alternatives/default.plymouth"
case "$applied" in
*plymouth/themes/minimal/minimal.plymouth) ;;
*) die "default.plymouth does not point at the Kzhento theme: $applied" ;;
esac
ok "default.plymouth selects the Kzhento theme"

# Welcome Center strings. The catalogues live in their own locale directory;
# a zh_CN catalogue filed under en/ would never be read.
for lang in en zh_CN; do
    unsquashfs -cat "$TMP/$layer" "/usr/share/locale/$lang/LC_MESSAGES/kubuntu-notification-helper.mo" \
        >"$TMP/$lang.mo" 2>/dev/null ||
        die "Missing in image: /usr/share/locale/$lang/LC_MESSAGES/kubuntu-notification-helper.mo"
    LC_ALL=C grep -aq 'K-Zhento' "$TMP/$lang.mo" ||
        die "Welcome Center catalogue for $lang does not mention K-Zhento"
    ok "Welcome Center catalogue present and rebranded: $lang"
done

unsquashfs -cat "$TMP/$layer" /etc/xdg/kcm-about-distrorc >"$TMP/kcm-about-distrorc" 2>/dev/null ||
    die "Missing in image: /etc/xdg/kcm-about-distrorc"
grep -qx 'Name=K-Zhento' "$TMP/kcm-about-distrorc" ||
    die "About this System name is not K-Zhento"
grep -qx 'LogoPath=start-here-kde' "$TMP/kcm-about-distrorc" ||
    die "About this System logo is not start-here-kde"
ok "About this System branded via /etc/xdg/kcm-about-distrorc"

# os-release LOGO= must agree with the icon the About page asks for.
grep -qx 'LOGO=start-here-kde' "$TMP/os-release" ||
    die "/etc/os-release does not set LOGO=start-here-kde"
ok "os-release LOGO matches the About page icon"

printf '\nAll artifact checks passed for %s\n' "$ISO"
