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

for c in xorriso unsquashfs md5sum sha256sum cmp cpio python3 awk sed grep; do
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
LABEL="Kzhento ${VERSION} amd64"
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

# unpack_initramfs <file> <dir>: expand every cpio segment of an initramfs.
# `cpio -id` alone stops at the first TRAILER!!!, so an archive with microcode
# segments in front of the root tree unpacks to just the microcode. Segments may
# be uncompressed cpio or compressed; later entries win, as they do in the kernel.
unpack_initramfs() {
    local file=$1 dir=$2
    rm -rf "$dir"
    mkdir -p "$dir"
    python3 - "$file" "$dir" <<'PY' || return 1
import subprocess
import sys

path, dest = sys.argv[1], sys.argv[2]
data = open(path, 'rb').read()
pos = 0
found = 0

while pos < len(data):
    while pos < len(data) and data[pos] == 0:
        pos += 1
    if pos >= len(data):
        break
    magic = data[pos:pos + 4]
    if magic == b'\x28\xb5\x2f\xfd':
        raw = subprocess.run(['zstd', '-dc'], input=data[pos:],
                             capture_output=True).stdout
        pos = len(data)
    elif magic[:2] == b'\x1f\x8b':
        raw = subprocess.run(['gzip', '-dc'], input=data[pos:],
                             capture_output=True).stdout
        pos = len(data)
    elif data[pos:pos + 6] in (b'070701', b'070702'):
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
        raw = data[pos:i]
        pos = i
    else:
        break
    subprocess.run(['cpio', '-idm', '--quiet', '-D', dest], input=raw,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    found += 1

if not found:
    raise SystemExit('no initramfs segment found')
PY
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
#
# The alternative is a symlink, and "unsquashfs -cat" follows it: asking for the
# link returns the *contents* of the theme file it points at, never its target.
# The target only appears in the listing, so read the mode and link text from
# there. A real file or a dangling link must not pass either.
plink=$(unsquashfs -lls "$TMP/$layer" /etc/alternatives/default.plymouth 2>/dev/null |
    sed -n 's/^\([^ ]*\) [^ ]* *[0-9]* [0-9-]* [0-9:]* squashfs-root\(.*\)$/\1 \2/p' |
    awk '$2 == "/etc/alternatives/default.plymouth" { print $1, $NF; exit }')
case "$plink" in
"") die "default.plymouth is missing from the listing" ;;
l*) ;;
*) die "default.plymouth is not a symlink (mode ${plink%% *})" ;;
esac
applied=${plink#* }
case "$applied" in
*plymouth/themes/minimal/minimal.plymouth) ;;
*) die "default.plymouth does not point at the Kzhento theme: $applied" ;;
esac
# The link is relative and resolved inside the image, so the theme it names has
# to exist there: a target that reads right but is missing still boots stock.
unsquashfs -cat "$TMP/$layer" /usr/share/plymouth/themes/minimal/minimal.plymouth \
    >/dev/null 2>&1 ||
    die "default.plymouth points at $applied, which is missing from the image"
ok "default.plymouth selects the Kzhento theme ($applied)"

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

# The Welcome Center's own first page. The catalogue above only brands the
# notification that opens the window; the page itself is QML with the Kubuntu
# text and artwork written into it, so a build that stops at the catalogue shows
# a window titled K-Zhento containing Kubuntu's tour.
about_page=usr/share/plasma/plasma-welcome/extra-pages/01-Kubuntu.qml
unsquashfs -cat "$TMP/$layer" "/$about_page" >"$TMP/welcome-page.qml" 2>/dev/null ||
    die "Missing in image: /$about_page"
grep -q 'Welcome to K-Zhento' "$TMP/welcome-page.qml" ||
    die "The Welcome Center page heading is not K-Zhento"
if grep -qi 'kubuntu\.org' "$TMP/welcome-page.qml"; then
    die "The Welcome Center page still links to kubuntu.org"
fi
ok "Welcome Center page rebranded: /$about_page"

# It draws a wordmark from the image, so the page is only correct if that file is
# there too - a missing PNG is a blank slot, not a fallback.
unsquashfs -cat "$TMP/$layer" /usr/share/plasma/plasma-welcome/extra-pages/kzhento-logo.png \
    >"$TMP/welcome-logo.png" 2>/dev/null ||
    die "Missing in image: /usr/share/plasma/plasma-welcome/extra-pages/kzhento-logo.png"
[ "$(head -c 8 "$TMP/welcome-logo.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] ||
    die "The Welcome Center wordmark is not a PNG"
ok "Welcome Center wordmark present"

# The stock page is kept for rollback, and *only* as the backup: a second *.qml
# in that directory is enumerated by plasma-welcome as one more page.
if unsquashfs -cat "$TMP/$layer" \
    /usr/share/plasma/plasma-welcome/extra-pages/01-Kubuntu.qml.zhento-orig >/dev/null 2>&1; then
    ok "stock Welcome Center page kept as .zhento-orig"
else
    die "The stock Welcome Center page was not kept as .zhento-orig"
fi
pages=$(unsquashfs -ll "$TMP/$layer" /usr/share/plasma/plasma-welcome/extra-pages 2>/dev/null |
    awk '$NF ~ /\.qml$/ { n++ } END { print n + 0 }')
[ "$pages" -eq 1 ] || die "$pages .qml pages in extra-pages, expected exactly 1"
ok "exactly one Welcome Center page in the image"

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

# The icon name has to resolve inside the image, and to the Kzhento mark rather
# than the KDE one. The page asks for an icon *name* (QIcon::fromTheme), so a
# file path would silently draw nothing; and the stock Breeze artwork is an SVG
# that must be gone, or a loader preferring SVG keeps drawing the KDE logo.
#
# The 128 px hicolor copy is the one the About page resolves: Kirigami asks for
# iconSizes.enormous, which is 128, and hicolor is the theme every toolkit falls
# back to. The size is read from the PNG header, not trusted from the path.
unsquashfs -cat "$TMP/$layer" /usr/share/icons/hicolor/128x128/places/start-here-kde.png \
    >"$TMP/about-icon.png" 2>/dev/null ||
    die "Missing in image: /usr/share/icons/hicolor/128x128/places/start-here-kde.png"
[ "$(head -c 8 "$TMP/about-icon.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] ||
    die "The About page icon is not a PNG"
python3 - "$TMP/about-icon.png" <<'PY' || die "The About page icon is not a 128 px image"
import struct
import sys

with open(sys.argv[1], "rb") as f:
    head = f.read(24)
width, height = struct.unpack(">II", head[16:24])
if (width, height) != (128, 128):
    sys.exit(f"{width}x{height}")
PY
ok "About page icon installed at 128x128 (start-here-kde in hicolor)"

# Breeze is the desktop's theme, so the launcher's copy matters too. Its stock
# file is an SVG; a PNG of the same name next to it would be ambiguous, so the
# build moves the SVG aside and removes it.
mode=$(unsquashfs -lls "$TMP/$layer" /usr/share/icons/breeze/places/64/start-here-kde.png 2>/dev/null |
    sed -n 's/^\([^ ]*\) [^ ]* *[0-9]* [0-9-]* [0-9:]* squashfs-root\(.*\)$/\1 \2/p' |
    awk '$2 == "/usr/share/icons/breeze/places/64/start-here-kde.png" { print $1; exit }')
case "$mode" in
-*) ok "breeze start-here-kde.png is a regular file" ;;
"") die "Missing in image: /usr/share/icons/breeze/places/64/start-here-kde.png" ;;
*) die "breeze start-here-kde.png is not a regular file (mode $mode)" ;;
esac
if unsquashfs -cat "$TMP/$layer" /usr/share/icons/breeze/places/64/start-here-kde.svg \
    >/dev/null 2>&1; then
    die "The stock KDE start-here-kde.svg is still in the image; it must be removed, not just shadowed"
fi
unsquashfs -cat "$TMP/$layer" /usr/share/icons/breeze/places/64/start-here-kde.svg.zhento-orig \
    >/dev/null 2>&1 ||
    die "The stock start-here-kde.svg was not kept as .zhento-orig"
ok "breeze keeps the Kzhento PNG and the stock SVG only as .zhento-orig"

# 10. The initramfs GRUB loads must be this build's, carrying the live-boot
#     config.
#
#     update-initramfs writes /boot/initrd.img-<kver> inside the layer, but the
#     ISO boots from /casper/initrd, which lives outside every squashfs. A build
#     that repacks the layer without copying the initramfs out still passes every
#     check above - the theme file, the alternative and the artwork are all in
#     the layer - while the boot screen keeps drawing the base ISO's artwork.
#
#     The file is not a plain copy either: the live boot needs conf/uuid.conf and
#     conf/conf.d/default-boot-to-casper.conf, which a chroot rebuild drops. When
#     they are missing init falls back to BOOT=local, run-init has no root to
#     switch to and PID 1 dies - the kernel panic from issue #21. So the archive
#     is unpacked and the three things are checked rather than compared byte for
#     byte against the layer's copy, which is expected to differ.
if grep -q '/casper/initrd' "$TMP/grub.cfg"; then
    extract_iso /casper/initrd "$TMP/casper-initrd"

    kernel=$(unsquashfs -lls "$TMP/$layer" /boot 2>/dev/null |
        sed -n 's#.*squashfs-root/boot/initrd\.img-\([0-9][^ ]*\)$#\1#p' |
        sort -V | tail -n1)
    [ -n "$kernel" ] ||
        die "Cannot find /boot/initrd.img-<kernel> in $layer to compare against casper/initrd"

    mkdir -p "$TMP/casper-tree"
    unpack_initramfs "$TMP/casper-initrd" "$TMP/casper-tree" ||
        die "Cannot unpack casper/initrd from the ISO"

    [ -f "$TMP/casper-tree/init" ] ||
        die "casper/initrd has no /init: it is not a usable initramfs"
    ok "casper/initrd unpacks to a root tree"

    [ -f "$TMP/casper-tree/conf/conf.d/default-boot-to-casper.conf" ] ||
        die "casper/initrd is missing conf/conf.d/default-boot-to-casper.conf: BOOT falls back to local and PID 1 dies (issue #21)"
    ok "casper/initrd carries the BOOT=casper config"

    [ -f "$TMP/casper-tree/conf/uuid.conf" ] ||
        die "casper/initrd is missing conf/uuid.conf: casper cannot identify the medium"
    ok "casper/initrd carries conf/uuid.conf"

    # The ISO's copy must be this build's, not the base image's: it is the
    # rebuilt archive plus the injected config, so it cannot equal the layer's.
    unsquashfs -cat "$TMP/$layer" "/boot/initrd.img-$kernel" >"$TMP/boot-initrd" 2>/dev/null ||
        die "Cannot read /boot/initrd.img-$kernel from $layer"
    cmp -s "$TMP/casper-initrd" "$TMP/boot-initrd" &&
        die "casper/initrd was not rebuilt for kernel $kernel: it is a plain copy"
    ok "casper/initrd differs from the base ISO's copy"
else
    ok "GRUB does not load casper/initrd, nothing to sync"
fi

printf '\nAll artifact checks passed for %s\n' "$ISO"
