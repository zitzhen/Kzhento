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
#    before and after installation.
unsquashfs -cat "$TMP/$layer" /etc/passwd >"$TMP/passwd" 2>/dev/null ||
    die "Cannot read /etc/passwd from $layer"
awk -F: '
    NF != 7 { next }
    $3 == 0 || $3 >= 1000 { n++; if ($7 != "/bin/zsh") bad = bad " " $1 "(" $7 ")" }
    END {
        if (n == 0) { print "no account to check"; exit 1 }
        if (bad != "") { print "not on zsh:" bad; exit 1 }
    }
' "$TMP/passwd" || die "root or a regular account in the ISO does not use /bin/zsh"
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

printf '\nAll artifact checks passed for %s\n' "$ISO"
