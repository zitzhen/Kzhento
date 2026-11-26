#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# ZhenTo ISO build script (UEFI-only, no longer depends on Cubic)
#
#   sudo ./build.sh              Unpack official ISO -> install APPs in chroot -> repack -> output ISO
#   sudo ./build.sh --apps-only  Run install-app/*.sh only (inside chroot or on a real system)
#   sudo ./build.sh --check      Read-only preflight; exits before any apt/PPA changes
#
# Overridable environment variables:
#   BASE_ISO       Base ISO (default /home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso)
#   VERSION        Version string (default 0.1.0)
#   VOLID          Disc volume label (default "ZhenTo <VERSION> amd64")
#   WORK_DIR       Intermediate build directory (default <repo>/work, needs ~35G free)
#   OUT_DIR        Output directory (default <repo>/out)
#   PATCH_LAYERS   auto or space-separated casper layer file names
#   KEEP_WORK      1 to keep intermediate files for debugging
#   SQUASHFS_COMP  Squashfs compression algorithm (default inherited from original layer, e.g. xz; zstd is much faster)
#   SQUASHFS_BLOCK Squashfs block size (default inherited from original layer, usually 131072)
#
# Note: some Ubuntu 26.04 desktop ISOs use layered squashfs (described in casper/install-sources.yaml),
# while Kubuntu 26.04.1 uses a single casper/filesystem.squashfs. Both layouts are supported:
# only the default base layer (or the single filesystem layer) is modified; language and
# enhanced-secureboot overlay layers, when present, are left untouched.

set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SELF_DIR/$(basename "$0")"

BASE_ISO=${BASE_ISO:-/home/oliver/iso/ubuntu-26.04.1-desktop-amd64.iso}
VERSION=${VERSION:-0.1.0}
VOLID=${VOLID:-"ZhenTo ${VERSION} amd64"}
WORK_DIR=${WORK_DIR:-"$SELF_DIR/work"}
OUT_DIR=${OUT_DIR:-"$SELF_DIR/out"}
PATCH_LAYERS=${PATCH_LAYERS:-auto}
KEEP_WORK=${KEEP_WORK:-0}
SQUASHFS_COMP=${SQUASHFS_COMP:-}
SQUASHFS_BLOCK=${SQUASHFS_BLOCK:-}

ISO_NAME="zhenTo-${VERSION}-amd64.iso"
ISO_DIR="$WORK_DIR/iso"
ROOT_DIR="$WORK_DIR/root"
EFI_IMG="$WORK_DIR/efi.img"

RESOLV_RESTORE=""

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}

human() {
    awk -v b="$1" 'BEGIN { printf "%.1fG", b / 1024 / 1024 / 1024 }'
}

# ISO 9660 volume label (-V) is limited to 32 characters; exceeding it makes xorriso fail.
# Truncate it here to keep things consistent.
if [ "${#VOLID}" -gt 32 ]; then
    warn "Volume label exceeds 32 chars (${#VOLID}); truncating to: ${VOLID:0:32}"
    VOLID=${VOLID:0:32}
fi

# ---------------------------------------------------------------------------
# Read-only preflight: safe to run before any apt/PPA or filesystem changes.
# ---------------------------------------------------------------------------
preflight_checks() {
    [ "$(id -u)" -eq 0 ] || die "root is required (chroot / mount): sudo $0 --check"
    for c in xorriso unsquashfs mksquashfs rsync dd awk; do
        command -v "$c" >/dev/null || die "Missing command: $c"
    done
    [ -f "$BASE_ISO" ] || die "Base ISO not found: $BASE_ISO"

    local space_dir="."
    if [ -d "$OUT_DIR" ]; then
        space_dir="$OUT_DIR"
    elif [ -d "$(dirname "$OUT_DIR")" ]; then
        space_dir=$(dirname "$OUT_DIR")
    elif [ -d "$(dirname "$WORK_DIR")" ]; then
        space_dir=$(dirname "$WORK_DIR")
    fi
    [ -w "$space_dir" ] || die "Output directory is not writable: $space_dir"

    local avail_gb
    avail_gb=$(df -Pk "$space_dir" | awk 'NR==2{print int($4/1024/1024)}')
    [ "$avail_gb" -ge 25 ] || die "Not enough disk space: ${avail_gb}G available (need >= 25G)"

    local f
    for f in "$SELF_DIR/edit-os-release/edit.sh" "$SELF_DIR/edit-grub/replace-grub.sh" \
        "$SELF_DIR/edit-logo.sh/edit-logo.sh" "$SELF_DIR/install-app/ppa.list" \
        "$SELF_DIR/edit-terminal/edit-terminal.sh" \
        "$SELF_DIR/edit-etc-default-useradd/edit-etc-default-useradd.sh" \
        "$SELF_DIR/edit-etc-default-useradd/useradd" \
        "$SELF_DIR/edit-etc-default-useradd/.zshrc"; do
        [ -f "$f" ] || die "Missing build input: $f"
    done

    # Branding steps are optional: an older checkout or a deliberately minimal
    # tree can skip them, but a half-present step is a hard error.
    local d
    for d in edit-plymouth/edit-plymouth.sh edit-plymouth/select-theme.sh \
        edit-plymouth/render.py edit-plymouth/plymouth/minimal.plymouth \
        edit-logo.sh/edit-pixmaps.sh edit-logo.sh/edit-icons.sh \
        edit-notification/edit-notification.sh \
        edit-notification/edit-welcome.sh edit-notification/plasma-welcome/01-Kzhento.qml \
        edit-os-release/edit-about-system.sh edit-os-release/kcm-about-distrorc; do
        if [ ! -f "$SELF_DIR/$d" ]; then
            warn "Branding input missing, its step will be skipped: $d"
        fi
    done

    if [ -f "$SELF_DIR/tests/check-version-consistency.sh" ]; then
        bash "$SELF_DIR/tests/check-version-consistency.sh"
    else
        warn "Version consistency check not found; skipping"
    fi

    local image_version
    image_version=$(sed -n 's/^VERSION_ID="\([^"]*\)"$/\1/p' "$SELF_DIR/edit-os-release/os-release")
    [ "$image_version" = "$VERSION" ] ||
        die "Requested VERSION=$VERSION but os-release VERSION_ID=$image_version; update branding first"

    log "Preflight OK (root, commands, base ISO, space, build inputs, versions)"
}

if [ "${1:-}" = "--check" ]; then
    preflight_checks
    exit 0
fi

# ---------------------------------------------------------------------------
# install PPA repositories
# ---------------------------------------------------------------------------
install_ppa_repositories() {
    local ppa_list="$SELF_DIR/install-app/ppa.list"
    local ppa

    [ -f "$ppa_list" ] || {
        warn "ppa.list not found: $ppa_list, skipping PPA setup"
        return 0
    }

    # add-apt-repository comes from software-properties-common
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        log "Installing software-properties-common"
        apt-get update
        apt-get install -y --no-install-recommends software-properties-common ||
            die "Failed to install software-properties-common"
    fi

    log "Adding PPA repositories from $ppa_list"
    while IFS= read -r ppa || [ -n "$ppa" ]; do
        # Trim whitespace; skip empty lines and comments
        ppa=$(printf '%s\n' "$ppa" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$ppa" ] && continue
        case "$ppa" in \#*) continue ;; esac

        log "Adding $ppa"
        add-apt-repository -y "$ppa" || die "Failed to add PPA: $ppa"
    done <"$ppa_list"
}

# ---------------------------------------------------------------------------
# Prepare apt inside the target system. Target PPAs are added only here:
# the host runner's codename may differ from the base ISO's (e.g. noble host
# vs resolute image), so adding them on the host would break apt update.
# ---------------------------------------------------------------------------
prepare_apt() {
    install_ppa_repositories
    log "Updating apt package index"
    apt-get update
}

# ---------------------------------------------------------------------------
# Preinstall APPs: run scripts under install-app/ on a real system or inside chroot
# ---------------------------------------------------------------------------
install_apps() {
    local app
    local found=0

    cd "$SELF_DIR"
    echo "==> Installing preinstalled applications..."

    for app in install-app/*.sh; do
        [ -e "$app" ] || continue
        found=1
        echo "==> Running ${app}"
        sh "$app"
    done

    [ "$found" -eq 1 ] || echo "==> No scripts under install-app/"
    echo "==> All applications installed."
}

if [ "${1:-}" = "--apps-only" ]; then
    prepare_apt
    install_apps
    exit 0
fi

# ---------------------------------------------------------------------------
# Cleanup: unmount bind mounts, restore resolv.conf
# ---------------------------------------------------------------------------
cleanup() {
    local m
    set +e
    if [ -d "$ROOT_DIR" ]; then
        for m in cdrom run sys proc dev/pts dev; do
            if mountpoint -q "$ROOT_DIR/$m" 2>/dev/null; then
                umount -R "$ROOT_DIR/$m" 2>/dev/null || umount -l "$ROOT_DIR/$m" 2>/dev/null
            fi
        done
        if [ -n "${RESOLV_RESTORE:-}" ]; then
            rm -f "$ROOT_DIR/etc/resolv.conf"
            ln -s "$RESOLV_RESTORE" "$ROOT_DIR/etc/resolv.conf" 2>/dev/null
            RESOLV_RESTORE=""
        fi
    fi
    set -e
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Read the base layer of the default install source from install-sources.yaml
# ---------------------------------------------------------------------------
detect_default_layer() {
    awk '
        /^- default: true/  { def = 1; next }
        /^- default: false/ { def = 0; next }
        def && /^  path: /  { sub(/^  path: /, ""); print; exit }
    ' "$ISO_DIR/casper/install-sources.yaml"
}

# ---------------------------------------------------------------------------
# Inject build-time helper commands into the chroot (they are not shipped in the final image)
# ---------------------------------------------------------------------------
write_chroot_helpers() {
    local bin="$ROOT_DIR/opt/zhento-build/bin"
    install -d "$bin"

    cat >"$bin/zhento-flatpak" <<'EOS'
#!/bin/sh
# Build-time flatpak preinstall: zhento-flatpak <app-id> [...]
set -e
export DEBIAN_FRONTEND=noninteractive

command -v flatpak >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y --no-install-recommends flatpak ca-certificates
}

flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

[ "$#" -gt 0 ] || { echo "Usage: zhento-flatpak <app-id>..." >&2; exit 2; }

for id in "$@"; do
    flatpak install --system -y --noninteractive flathub "$id"
done
EOS

    cat >"$bin/zhento-snap" <<'EOS'
#!/bin/sh
# Build-time snap preinstall: snapd is not running inside chroot, so we write the seed
# instead of running "snap install".
# Note: only works when the image ships its own seed.yaml; otherwise it errors out.
set -e
export DEBIAN_FRONTEND=noninteractive

command -v snap >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y --no-install-recommends snapd
}

SEED=/var/lib/snapd/seed
CHANNEL=${SNAP_CHANNEL:-stable}

[ -f "$SEED/seed.yaml" ] || {
    echo "XX  No $SEED/seed.yaml in the image; cannot preinstall snap; use apt or flatpak instead" >&2
    exit 1
}

[ "$#" -gt 0 ] || { echo "Usage: zhento-snap <snap-name>..." >&2; exit 2; }

for name in "$@"; do
    tmp=$(mktemp -d)
    (
        cd "$tmp"
        snap download "$name" --channel="$CHANNEL"
    )
    snapfile=$(ls "$tmp"/*.snap | head -n1)
    assertfile=$(ls "$tmp"/*.assert | head -n1)
    base=$(basename "$snapfile")

    install -m 0644 "$snapfile" "$SEED/snaps/$base"
    install -m 0644 "$assertfile" "$SEED/assertions/$(basename "$assertfile")"

    if grep -q "^  - name: ${name}$" "$SEED/seed.yaml"; then
        rm -rf "$tmp"
        continue
    fi

    entry=$(printf '  - name: %s\n    channel: %s\n    file: %s\n' "$name" "$CHANNEL" "$base")
    awk -v block="$entry" '
        /^[a-zA-Z]/ && !done { print block; done = 1 }
        { print }
        END { if (!done) print block }
    ' "$SEED/seed.yaml" > "$SEED/seed.yaml.new"
    mv "$SEED/seed.yaml.new" "$SEED/seed.yaml"

    rm -rf "$tmp"
done
EOS

    chmod 0755 "$bin/zhento-flatpak" "$bin/zhento-snap"
}

# ---------------------------------------------------------------------------
# Default login shell for accounts created after installation:
# /etc/default/useradd gets Kzhento's SHELL=/bin/zsh. Runs on the host against
# $ROOT_DIR, so nothing extra is copied into the image.
# ---------------------------------------------------------------------------
apply_useradd_defaults() {
    local src="$SELF_DIR/edit-etc-default-useradd/edit-etc-default-useradd.sh"

    [ -f "$src" ] || {
        warn "edit-etc-default-useradd/edit-etc-default-useradd.sh is missing, skipping /etc/default/useradd"
        return 0
    }

    log "Writing /etc/default/useradd (new accounts use zsh)"
    sh "$src" "$ROOT_DIR/etc/default/useradd" ||
        die "Failed to write /etc/default/useradd"
}

# ---------------------------------------------------------------------------
# Existing accounts: rewrite the login shell in /etc/passwd to zsh and install
# the Kzhento .zshrc (Starship) into /etc/skel and every existing home
# directory. Runs inside the chroot as root so the passwd it edits is the
# image's own. Both payload trees go under /opt/zhento-build and are deleted
# with the rest of the build-time artifacts, so nothing extra ships in the
# image.
# ---------------------------------------------------------------------------
apply_terminal() {
    local src="$SELF_DIR/edit-terminal"
    local dst=/opt/zhento-build/edit-terminal
    local config_src="$SELF_DIR/edit-etc-default-useradd"
    local config_dst=/opt/zhento-build/edit-etc-default-useradd

    [ -f "$src/edit-terminal.sh" ] || {
        warn "edit-terminal/edit-terminal.sh is missing, skipping login shells"
        return 0
    }
    [ -f "$config_src/.zshrc" ] || {
        warn "edit-etc-default-useradd/.zshrc is missing, skipping login shells"
        return 0
    }

    log "Switching existing accounts to zsh and installing .zshrc"
    # The script rewrites <root>/etc/passwd; a chroot that is not running as
    # uid 0 silently cannot do that, so check the identity explicitly instead
    # of trusting a success message that never happened.
    chroot_uid=$(chroot "$ROOT_DIR" /bin/sh -c 'id -u') ||
        die "Cannot run a command inside the chroot"
    [ "$chroot_uid" = 0 ] ||
        die "chroot runs as uid $chroot_uid, not 0; /etc/passwd cannot be rewritten"
    log "chroot runs as uid 0, rewriting /etc/passwd is allowed"
    rm -rf "$ROOT_DIR$dst" "$ROOT_DIR$config_dst"
    cp -a "$src" "$ROOT_DIR$dst"
    cp -a "$config_src" "$ROOT_DIR$config_dst"
    chroot "$ROOT_DIR" /usr/bin/env -i \
        HOME=/root TERM=dumb LC_ALL=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        ZSHRC_SRC="$config_dst/.zshrc" /bin/sh -c "cd $dst && ./edit-terminal.sh" ||
        die "Failed to switch login shells to zsh"
    grep -q '^root:[^:]*:0:0:[^:]*:/root:/bin/zsh$' "$ROOT_DIR/etc/passwd" ||
        die "root is still not on /bin/zsh in $ROOT_DIR/etc/passwd after edit-terminal.sh"
}

# ---------------------------------------------------------------------------
# Branding: copy edit-os-release/ into the chroot and run it to rewrite the image's os-release
# ---------------------------------------------------------------------------
apply_os_release() {
    local src="$SELF_DIR/edit-os-release"
    local dst=/opt/zhento-build/edit-os-release

    [ -d "$src" ] || {
        warn "edit-os-release/ is missing, skipping os-release"
        return 0
    }

    log "Writing os-release"
    rm -rf "$ROOT_DIR$dst"
    cp -a "$src" "$ROOT_DIR$dst"
    chroot "$ROOT_DIR" /bin/sh "$dst/edit.sh" || die "Failed to write os-release"
}

# ---------------------------------------------------------------------------
# Logo: download the artwork from kzhento-icon at build time and install it
# ---------------------------------------------------------------------------
apply_logo() {
    local script="$SELF_DIR/edit-logo.sh/edit-logo.sh"

    [ -f "$script" ] || {
        warn "edit-logo.sh/edit-logo.sh is missing, skipping logo"
        return 0
    }

    # The artwork is installed twice: as /usr/share/backgrounds/kzhento and as
    # /usr/share/pixmaps/ubuntu-logo-text-dark.png (what the Plymouth themes
    # draw and what upstream tools call the distro wordmark). The second copy
    # is rendered from the first, so both come from the same download.
    log "Installing Kzhento logo"
    sh "$script" "$ROOT_DIR" || die "Failed to install logo"
}

# ---------------------------------------------------------------------------
# Wordmark: replace /usr/share/pixmaps/ubuntu-logo-text-dark.png
# ---------------------------------------------------------------------------
apply_pixmap_logo() {
    local script="$SELF_DIR/edit-logo.sh/edit-pixmaps.sh"

    [ -f "$script" ] || {
        warn "edit-logo.sh/edit-pixmaps.sh is missing, skipping the wordmark"
        return 0
    }

    log "Installing Kzhento wordmark"
    sh "$script" "$SELF_DIR/logo" "$ROOT_DIR" || die "Failed to install wordmark"
}

# ---------------------------------------------------------------------------
# Distro icon: replace the stock start-here-kde artwork. This is what the "About
# this System" page draws (LogoPath=start-here-kde) and what Plasma uses for the
# application launcher, so it has to be the Kzhento mark, not the KDE bundle's.
# ---------------------------------------------------------------------------
apply_icons() {
    local script="$SELF_DIR/edit-logo.sh/edit-icons.sh"

    [ -f "$script" ] || {
        warn "edit-logo.sh/edit-icons.sh is missing, skipping the distro icon"
        return 0
    }
    # The step rewrites the start-here-kde entries of the icon themes' Places
    # directories; an image without KDE has neither, and then there is no About
    # page to brand either. Check for the directory the step actually writes,
    # not just for /usr/share/icons, so a half-present tree is a skip with a
    # reason rather than a failure halfway through the install.
    if ! ls -d "$ROOT_DIR"/usr/share/icons/*/places >/dev/null 2>&1; then
        warn "No icon theme with Places directories in the image, skipping the distro icon"
        return 0
    fi

    log "Installing Kzhento start-here-kde icon"
    sh "$script" "$SELF_DIR/logo" "$ROOT_DIR" || die "Failed to install the distro icon"
}

# ---------------------------------------------------------------------------
# Boot splash: Kzhento theme + artwork for the stock spinner theme. The initramfs
# is rebuilt afterwards by apply_plymouth_theme, once the chroot is gone.
# ---------------------------------------------------------------------------
apply_plymouth() {
    local script="$SELF_DIR/edit-plymouth/edit-plymouth.sh"

    [ -f "$script" ] || {
        warn "edit-plymouth/edit-plymouth.sh is missing, skipping the boot splash"
        return 0
    }

    log "Installing Kzhento boot splash"
    sh "$script" "$ROOT_DIR" || die "Failed to install boot splash"
}

# ---------------------------------------------------------------------------
# Boot splash, part 2: select the theme and rebuild the initramfs. Runs after
# the chroot has been torn down, because update-initramfs needs /proc and /sys.
# ---------------------------------------------------------------------------
apply_plymouth_theme() {
    local script="$SELF_DIR/edit-plymouth/select-theme.sh"

    [ -f "$script" ] || {
        warn "edit-plymouth/select-theme.sh is missing, skipping the initramfs rebuild"
        return 0
    }
    [ -d "$ROOT_DIR/usr/share/plymouth/themes/minimal" ] || return 0

    log "Selecting the boot splash theme and rebuilding the initramfs"
    sh "$script" "$ROOT_DIR" || die "Failed to select the boot splash theme"
}

# ---------------------------------------------------------------------------
# Boot splash, part 3: put the rebuilt initramfs where GRUB actually reads it.
#
# update-initramfs only writes /boot/initrd.img-<kver> inside the layer, but the
# ISO boots from /casper/initrd, outside every squashfs. Without this copy the
# rebuilt initramfs is packaged and never loaded: the boot screen keeps drawing
# whatever the base ISO's initramfs carried, which is why a fully branded image
# still showed the stock Kubuntu logo.
#
# Copying it wholesale is not enough. The live boot needs two files that a chroot
# rebuild drops:
#
#   conf/uuid.conf                            which medium this initramfs belongs to
#   conf/conf.d/default-boot-to-casper.conf   BOOT=casper instead of BOOT=local
#
# Neither is installed by the casper package: its initramfs hook writes them only
# when CASPER_GENERATE_UUID is set, which the stock image build does and this
# rebuild does not. Without them init falls back to BOOT=local, run-init has no
# root to switch to, and PID 1 dies with "No root device specified" -> the
# initramfs rescue shell -> "Attempted to kill init!" -> kernel panic.
#
# They are injected by unpacking every segment, adding the two files and packing
# the tree back. Two cheaper shortcuts do not work and are worth recording:
#
#   - appending a small cpio segment at the end. The kernel reads the trailing
#     segment as another archive and fails with "Initramfs unpacking failed:
#     invalid magic at start of compressed archive", which is worse than the
#     bug being fixed.
#   - `cpio -id` on the archive. It stops at the first TRAILER!!! and unpacks
#     only the leading microcode segment, silently losing the whole root tree.
#
# The repacked archive is one uncompressed cpio, the same shape the stock
# casper/initrd has (early microcode is re-emitted first, in tree order).
# ---------------------------------------------------------------------------
sync_casper_boot() {
    local kernel versioned casper_vmlinuz casper_initrd casper_uuid work

    [ -f "$ROOT_DIR/etc/initramfs-tools/initramfs.conf" ] || {
        warn "No initramfs-tools in the image, skipping the casper/ boot file sync"
        return 0
    }
    [ -d "$ISO_DIR/casper" ] || {
        warn "No casper/ directory in the ISO tree, skipping the boot file sync"
        return 0
    }

    kernel=$(cd "$ROOT_DIR/boot" 2>/dev/null && basename "$(readlink -f vmlinuz 2>/dev/null)" 2>/dev/null) || true
    kernel=${kernel#vmlinuz-}
    versioned="$ROOT_DIR/boot/initrd.img-$kernel"
    [ -n "$kernel" ] && [ -f "$versioned" ] || {
        warn "No rebuilt /boot/initrd.img-<kernel> in the image, skipping the casper/ boot file sync"
        return 0
    }

    casper_vmlinuz="$ISO_DIR/casper/vmlinuz"
    if [ -f "$ROOT_DIR/boot/vmlinuz-$kernel" ] && ! cmp -s "$ROOT_DIR/boot/vmlinuz-$kernel" "$casper_vmlinuz"; then
        log "Syncing casper/vmlinuz with the patched /boot/vmlinuz-$kernel"
        cp -f "$ROOT_DIR/boot/vmlinuz-$kernel" "$casper_vmlinuz"
        chmod 0644 "$casper_vmlinuz"
    fi

    # The UUID must be the one the medium advertises, or casper refuses the disc
    # it was built for (scripts/casper:matches_uuid compares it against
    # /.disk/casper-uuid-*). A random UUID would be worse than none.
    casper_uuid=$(head -n1 "$ISO_DIR/.disk/casper-uuid-generic" 2>/dev/null) || casper_uuid=''
    [ -n "$casper_uuid" ] || {
        warn "No .disk/casper-uuid-generic in the ISO tree; live boot may reject the rebuilt initramfs"
        casper_uuid=$(uuidgen -r 2>/dev/null) || casper_uuid=''
    }

    work=$(mktemp -d "$WORK_DIR/casper-initrd.XXXXXX")
    unpack_initramfs "$versioned" "$work/tree" ||
        die "Cannot unpack the rebuilt initramfs: $versioned"

    mkdir -p "$work/tree/conf/conf.d"
    [ -n "$casper_uuid" ] && printf '%s\n' "$casper_uuid" >"$work/tree/conf/uuid.conf"
    cat >"$work/tree/conf/conf.d/default-boot-to-casper.conf" <<'CONF'
if [ -z "$BOOT" ]; then
    export BOOT=casper
fi
CONF

    repack_initramfs "$work/tree" "$work/initrd" ||
        die "Cannot repack the casper initramfs"

    casper_initrd="$ISO_DIR/casper/initrd"
    log "Installing the rebuilt initramfs as casper/initrd (kernel $kernel, uuid ${casper_uuid:-none})"
    chmod 0644 "$work/initrd"
    mv -f "$work/initrd" "$casper_initrd" || die "Cannot replace $casper_initrd"
    cmp -s "$versioned" "$casper_initrd" &&
        die "casper/initrd equals the rebuilt initramfs: the live-boot config was not injected"

    rm -rf "$work"
}

# unpack_initramfs <file> <dir>: expand every cpio segment of an initramfs.
#
# `cpio -id` alone stops at the first TRAILER!!!, so an archive that carries
# microcode segments in front of the root tree unpacks to just the microcode.
# The segments are walked explicitly and each one is unpacked into the same
# tree; later entries overwrite earlier ones, which is what the kernel does.
# A segment may be an uncompressed cpio or a compressed one.
unpack_initramfs() {
    local file=$1 dir=$2
    rm -rf "$dir"
    mkdir -p "$dir"
    python3 - "$file" "$dir" <<'PY' || return 1
import os
import subprocess
import sys

path, dest = sys.argv[1], sys.argv[2]
data = open(path, 'rb').read()
pos = 0
unpacked = 0

while pos < len(data):
    # Skip alignment padding between segments.
    while pos < len(data) and data[pos] == 0:
        pos += 1
    if pos >= len(data):
        break

    magic = data[pos:pos + 4]
    if magic == b'\x28\xb5\x2f\xfd':            # zstd
        raw = subprocess.run(['zstd', '-dc'], input=data[pos:],
                             capture_output=True).stdout
        consumed = len(data) - pos
    elif magic[:2] == b'\x1f\x8b':              # gzip
        raw = subprocess.run(['gzip', '-dc'], input=data[pos:],
                             capture_output=True).stdout
        consumed = len(data) - pos
    elif data[pos:pos + 6] in (b'070701', b'070702'):   # uncompressed cpio
        raw = data[pos:]
        consumed = 0
        # Walk this segment's entries to find its exact length.
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
        consumed = i - pos
    else:
        raise SystemExit('unrecognized initramfs segment at offset %d' % pos)

    result = subprocess.run(['cpio', '-idm', '--quiet', '-D', dest],
                            input=raw, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    unpacked += 1

    if consumed == 0:
        break
    pos += consumed

if not unpacked:
    raise SystemExit('no initramfs segment found in %s' % path)
PY
}

# repack_initramfs <dir> <file>: write the tree back as one uncompressed cpio
# archive, the layout the stock casper/initrd uses.
repack_initramfs() {
    local dir=$1 file=$2
    (cd "$dir" && find . | cpio -o -H newc --quiet) >"$file" 2>/dev/null || return 1
    [ -s "$file" ]
}

# ---------------------------------------------------------------------------
# Welcome Center: Kzhento strings for kubuntu-notification-helper
# ---------------------------------------------------------------------------
apply_notification() {
    local script="$SELF_DIR/edit-notification/edit-notification.sh"

    [ -f "$script" ] || {
        warn "edit-notification/edit-notification.sh is missing, skipping the Welcome Center"
        return 0
    }

    log "Rebranding the Welcome Center"
    sh "$script" "$ROOT_DIR" || die "Failed to rebrand the Welcome Center"
}

# ---------------------------------------------------------------------------
# Welcome Center page: the first-login tour's own first page. The notification
# above is what opens the window; this is the window's content, which is QML with
# the Kubuntu text and artwork written into it and no catalogue to override.
# ---------------------------------------------------------------------------
apply_welcome_page() {
    local script="$SELF_DIR/edit-notification/edit-welcome.sh"

    [ -f "$script" ] || {
        warn "edit-notification/edit-welcome.sh is missing, skipping the Welcome Center page"
        return 0
    }
    [ -d "$ROOT_DIR/usr/share/plasma/plasma-welcome/extra-pages" ] || {
        warn "plasma-welcome is not installed in the image, skipping the Welcome Center page"
        return 0
    }

    log "Installing the K-Zhento Welcome Center page"
    LOGO_DIR="$SELF_DIR/logo" sh "$script" "$ROOT_DIR" ||
        die "Failed to install the Welcome Center page"
}

# ---------------------------------------------------------------------------
# About this System: kcm-about-distrorc for kcm_about-distro
# ---------------------------------------------------------------------------
apply_about_system() {
    local script="$SELF_DIR/edit-os-release/edit-about-system.sh"

    [ -f "$script" ] || {
        warn "edit-os-release/edit-about-system.sh is missing, skipping About this System"
        return 0
    }

    log "Branding About this System"
    sh "$script" "$ROOT_DIR" || die "Failed to brand About this System"
}

# ---------------------------------------------------------------------------
# Boot menu: replace boot/grub/grub.cfg in the ISO tree with the config from edit-grub/
# ---------------------------------------------------------------------------
apply_grub() {
    local src="$SELF_DIR/edit-grub"
    local dst="$ISO_DIR/boot/grub/grub.cfg"

    [ -f "$src/grub.cfg" ] || {
        warn "edit-grub/grub.cfg is missing, skipping boot menu"
        return 0
    }
    [ -f "$dst" ] || {
        warn "boot/grub/grub.cfg not found in ISO tree, skipping boot menu"
        return 0
    }

    log "Replacing boot menu grub.cfg"
    sh "$src/replace-grub.sh" "$dst" || die "Failed to replace grub.cfg"

    # The backup file is for rollback on a real system; it must not be included in the ISO
    rm -f "$dst".bak.*
}

# ---------------------------------------------------------------------------
# Process a single casper layer: unpack -> install APPs in chroot -> repack -> update metadata
# ---------------------------------------------------------------------------
patch_layer() {
    local layer="$1"
    local sfs="$ISO_DIR/casper/$layer"
    local size_file="$ISO_DIR/casper/${layer%.squashfs}.size"
    local comp block old_size new_size avail need
    local -a env_args

    [ -f "$sfs" ] || die "Layer file not found: $sfs"

    comp=$(unsquashfs -s "$sfs" | awk '/^Compression /{print $2}')
    block=$(unsquashfs -s "$sfs" | awk '/^Block size /{print $3}')
    [ -n "$comp" ] && [ -n "$block" ] || die "Cannot read squashfs parameters: $sfs"
    comp=${SQUASHFS_COMP:-$comp}
    block=${SQUASHFS_BLOCK:-$block}

    # Space check: unpacked size + new layer (base ISO is already on disk, not counted twice)
    need=$(($(stat -c%s "$sfs") * 3 / 2))
    if [ -f "$size_file" ]; then
        need=$((need + $(tr -d '\n' <"$size_file")))
    fi
    avail=$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4 * 1024}')
    if [ "$avail" -lt "$need" ]; then
        die "Not enough space: $WORK_DIR needs about $(human "$need"), available $(human "$avail"). Point WORK_DIR to a larger disk"
    fi

    log "Unpacking $layer ($comp / ${block} block)"
    rm -rf "$ROOT_DIR"
    unsquashfs -no-progress -d "$ROOT_DIR" "$sfs" >/dev/null

    log "Preparing chroot"
    install -d "$ROOT_DIR/opt/zhento-build" "$ROOT_DIR/dev" "$ROOT_DIR/dev/pts" \
        "$ROOT_DIR/proc" "$ROOT_DIR/sys" "$ROOT_DIR/run"
    cp -f "$SELF" "$ROOT_DIR/opt/zhento-build/build.sh"
    rm -rf "$ROOT_DIR/opt/zhento-build/install-app"
    cp -a "$SELF_DIR/install-app" "$ROOT_DIR/opt/zhento-build/install-app"
    write_chroot_helpers

    mount --bind /dev "$ROOT_DIR/dev"
    mount -t devpts devpts "$ROOT_DIR/dev/pts" 2>/dev/null || true
    mount --bind /proc "$ROOT_DIR/proc"
    mount --bind /sys "$ROOT_DIR/sys"
    mount -t tmpfs tmpfs "$ROOT_DIR/run"

    # The image ships a file:/cdrom apt source (offline install repo); without /cdrom in
    # the chroot, "apt update" fails outright. Bind-mount the ISO tree to fix the index and
    # also make the offline repo available.
    if [ -d "$ISO_DIR/dists" ]; then
        install -d "$ROOT_DIR/cdrom"
        mount --bind "$ISO_DIR" "$ROOT_DIR/cdrom"
    fi

    # resolv.conf inside the chroot is usually a systemd-resolved symlink; replace it with
    # a real file first.
    if [ -L "$ROOT_DIR/etc/resolv.conf" ]; then
        RESOLV_RESTORE=$(readlink "$ROOT_DIR/etc/resolv.conf")
        rm -f "$ROOT_DIR/etc/resolv.conf"
    fi
    cp -f /etc/resolv.conf "$ROOT_DIR/etc/resolv.conf"

    # Prevent postinst from starting services inside the chroot
    printf '#!/bin/sh\nexit 101\n' >"$ROOT_DIR/usr/sbin/policy-rc.d"
    chmod 0755 "$ROOT_DIR/usr/sbin/policy-rc.d"

    log "Running build.sh --apps-only inside chroot"
    env_args=(
        HOME=/root
        TERM=dumb
        LC_ALL=C.UTF-8
        DEBIAN_FRONTEND=noninteractive
        PATH=/opt/zhento-build/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    )
    local v
    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
        [ -n "${!v:-}" ] && env_args+=("$v=${!v}")
    done
    chroot "$ROOT_DIR" /usr/bin/env -i "${env_args[@]}" \
        /bin/bash /opt/zhento-build/build.sh --apps-only

    apply_os_release
    apply_about_system
    apply_logo
    apply_pixmap_logo
    apply_icons
    apply_plymouth
    apply_notification
    apply_welcome_page
    apply_useradd_defaults
    apply_terminal

    log "Cleaning up build-time artifacts"
    rm -rf "$ROOT_DIR/opt/zhento-build"
    rm -f "$ROOT_DIR/usr/sbin/policy-rc.d"
    rm -f "$ROOT_DIR"/var/cache/apt/archives/*.deb 2>/dev/null || true

    cleanup

    # After cleanup: the theme only reaches the boot screen once it is baked
    # into the initramfs, and that needs /proc and /sys inside the chroot.
    apply_plymouth_theme

    # The rebuilt initramfs lives inside the layer; the ISO boots from casper/,
    # so it has to be copied out before the layer is repacked.
    sync_casper_boot

    log "Repacking $layer"
    mksquashfs "$ROOT_DIR" "$WORK_DIR/$layer" \
        -comp "$comp" -b "$block" -noappend -no-progress -quiet
    mv -f "$WORK_DIR/$layer" "$sfs"

    # Update the layer size (casper uses it to compute the memory needed by the overlay).
    # The classic single-squashfs layout has filesystem.size but no install-sources.yaml.
    if [ -f "$size_file" ]; then
        old_size=$(tr -d '\n' <"$size_file")
        new_size=$(du -sb "$ROOT_DIR" | cut -f1)
        printf '%s\n' "$new_size" >"$size_file"
        if [ -f "$ISO_DIR/casper/install-sources.yaml" ]; then
            sed -i "s/^  size: ${old_size}$/  size: ${new_size}/" \
                "$ISO_DIR/casper/install-sources.yaml"
        fi
    fi

    rm -rf "$ROOT_DIR"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
    local layer start end interval report need avail
    local -a layer_list

    [ "$(id -u)" -eq 0 ] || die "root is required (chroot / mount): sudo $0"
    for c in xorriso unsquashfs mksquashfs rsync dd awk; do
        command -v "$c" >/dev/null || die "Missing command: $c"
    done
    [ -f "$BASE_ISO" ] || die "Base ISO not found: $BASE_ISO"

    mkdir -p "$OUT_DIR"
    rm -rf "$WORK_DIR"
    mkdir -p "$ISO_DIR"

    log "Extracting ISO tree to $ISO_DIR"
    xorriso -osirrox on:auto_chmod_on -indev "$BASE_ISO" -extract / "$ISO_DIR" >/dev/null

    [ -f "$ISO_DIR/casper/install-sources.yaml" ] ||
        [ -f "$ISO_DIR/casper/filesystem.squashfs" ] ||
        die "This ISO has neither casper/install-sources.yaml nor casper/filesystem.squashfs; it is not a supported Ubuntu desktop image"

    # Extract the FAT partition used for UEFI boot (the original disc uses an "appended partition",
    # not an efi.img file)
    log "Extracting EFI boot partition"
    report=$(LC_ALL=C xorriso -indev "$BASE_ISO" -report_el_torito as_mkisofs 2>/dev/null)
    interval=$(printf '%s\n' "$report" |
        sed -n "s/.*--interval:local_fs:\([0-9][0-9]*\)d-\([0-9][0-9]*\)d.*/\1 \2/p" |
        head -n1)
    [ -n "$interval" ] || die "Cannot parse EFI partition location from base ISO"
    start=${interval% *}
    end=${interval#* }
    dd if="$BASE_ISO" of="$EFI_IMG" bs=512 skip="$start" \
        count=$((end - start + 1)) status=none
    [ -s "$EFI_IMG" ] || die "EFI partition extraction failed"

    # Choose which layers to patch
    if [ "$PATCH_LAYERS" = "auto" ]; then
        if [ -f "$ISO_DIR/casper/install-sources.yaml" ]; then
            layer=$(detect_default_layer)
            [ -n "$layer" ] || die "Cannot determine the default install source from install-sources.yaml"
            layer_list=("$layer")
            warn "Only the above base layer(s) are processed; language and enhanced-secureboot overlay layers are kept as-is"
        else
            log "No install-sources.yaml; using the classic single casper/filesystem.squashfs layer"
            layer_list=("filesystem.squashfs")
        fi
    else
        read -r -a layer_list <<<"$PATCH_LAYERS"
    fi

    log "Layers to modify: ${layer_list[*]}"
    warn "casper/*.manifest are not regenerated (only affects installer package stats, not the install result)"

    for layer in "${layer_list[@]}"; do
        patch_layer "$layer"
    done

    apply_grub

    # boot.catalog is regenerated by xorriso; delete the old one in the ISO tree so md5sum
    # does not record stale content.
    rm -f "$ISO_DIR/boot.catalog"

    log "Rebuilding md5sum.txt"
    (
        cd "$ISO_DIR"
        find . -type f ! -name md5sum.txt -print0 |
            sort -z |
            xargs -0 md5sum >md5sum.txt
    )

    need=$(($(du -sb "$ISO_DIR" | cut -f1) * 105 / 100))
    avail=$(df -Pk "$OUT_DIR" | awk 'NR==2{print $4 * 1024}')
    [ "$avail" -ge "$need" ] ||
        die "Not enough space in output directory: need about $(human "$need"), available $(human "$avail")"

    log "Generating UEFI-only ISO: $ISO_NAME"
    rm -f "$OUT_DIR/$ISO_NAME"
    xorriso -as mkisofs \
        -r -V "$VOLID" -J -joliet-long -l -iso-level 3 \
        -partition_offset 16 \
        --protective-msdos-label \
        -append_partition 2 0xef "$EFI_IMG" \
        -appended_part_as_gpt \
        -e '--interval:appended_partition_2:all::' \
        -no-emul-boot \
        -o "$OUT_DIR/$ISO_NAME" "$ISO_DIR"

    (
        cd "$OUT_DIR"
        md5sum "$ISO_NAME" >"zhenTo-${VERSION}-amd64.md5"
    )

    log "Done"
    printf '  ISO : %s (%s)\n' "$OUT_DIR/$ISO_NAME" "$(human "$(stat -c%s "$OUT_DIR/$ISO_NAME")")"
    printf '  MD5 : %s\n' "$OUT_DIR/zhenTo-${VERSION}-amd64.md5"
    xorriso -indev "$OUT_DIR/$ISO_NAME" -report_el_torito plain 2>/dev/null |
        grep 'El Torito boot img' || true

    if [ "$KEEP_WORK" = "1" ]; then
        log "Keeping intermediate files: $WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}

main "$@"
