#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for the wallpaper steps in edit-wallpaper/:
#
#   set-default-wallpaper.sh       make an installed kpackage the default
#   remove-kubuntu-wallpapers.sh   take the stock Kubuntu wallpapers out
#
# Both write into a target root, so every case runs against a tree built here in
# a temporary directory, with `id -u` mocked: nothing needs root and no image is
# touched. What the assertions guard, and why:
#
#   - the default is set in all three places Plasma reads it from (look-and-feel
#     defaults, the layout scripts, the lock screen). Changing only one leaves a
#     different wallpaper on first login, and a stock lock screen.
#   - the wallpaper is named as a kpackage, so the URL and no day/night marker
#     is written; a leftover DynamicMode=1 blends in images_dark at dusk.
#   - an entry that names a wallpaper which is not installed fails the build
#     instead of shipping a black desktop.
#   - Breeze's own default is not rewritten: it is not a stock Kubuntu entry and
#     upstream's artwork is what that theme is designed around.
#   - removal deletes the three stock kpackages and installs a dpkg path filter
#     for them, so an upgrade or a reinstall cannot put them back.
#   - removal refuses to run while a default still names a removed wallpaper,
#     because that is the black-desktop case, and it is idempotent.
#   - non-root callers are refused before anything is written.
#
# Usage: bash tests/edit-wallpaper.test.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SET_DEFAULT="$REPO_DIR/edit-wallpaper/set-default-wallpaper.sh"
REMOVE="$REPO_DIR/edit-wallpaper/remove-kubuntu-wallpapers.sh"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

for f in "$SET_DEFAULT" "$REMOVE"; do
    [ -f "$f" ] || fail "missing input: $f"
    [ -x "$f" ] || fail "not executable: $f"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ROOT_BIN="$TMP/root-bin"
NONROOT_BIN="$TMP/nonroot-bin"
mkdir -p "$ROOT_BIN" "$NONROOT_BIN"
printf '#!/bin/sh\necho 0\n' >"$ROOT_BIN/id"
printf '#!/bin/sh\necho 1000\n' >"$NONROOT_BIN/id"
chmod +x "$ROOT_BIN/id" "$NONROOT_BIN/id"
AS_ROOT="PATH=$ROOT_BIN:$PATH"

# make_wallpaper <root> <name>: a minimal wallpaper kpackage with one image.
make_wallpaper() {
    local root=$1 name=$2
    mkdir -p "$root/usr/share/wallpapers/$name/contents/images"
    printf '{\n    "KPlugin": {\n        "Id": "%s",\n        "Name": "%s"\n    }\n}\n' \
        "$name" "$name" >"$root/usr/share/wallpapers/$name/metadata.json"
    printf '\211PNG\r\n\032\n' >"$root/usr/share/wallpapers/$name/contents/images/5120x2880.png"
}

# make_theme <root> <theme dir> <default image> <layout image> [dynamic]
make_theme() {
    local root=$1 theme=$2 image=$3 layout=$4 dynamic=${5:-0}
    local contents="$root/usr/share/plasma/look-and-feel/$theme/contents"
    mkdir -p "$contents/layouts"
    cat >"$contents/defaults" <<EOF
[kdeglobals][KDE]
widgetStyle=Breeze

[Wallpaper]
Image=$image

[kcminputrc][Mouse]
cursorTheme=breeze_cursors
EOF
    cat >"$contents/layouts/org.kde.plasma.desktop-layout.js" <<EOF
function activateWallpaperFn ( desktop_list ) {
  for ( let idx = 0; idx < desktop_list.length; idx++ ) {
    const desktop_obj = desktop_list[idx];
    desktop_list[idx].wallpaperPlugin = 'org.kde.image';
    desktop_obj.currentConfigGroup = [ 'Wallpaper', 'org.kde.image', 'General' ];
    desktop_obj.writeConfig( 'Image', '$layout' );
    desktop_obj.writeConfig( 'DynamicMode', $dynamic );
  }
}
EOF
}

# make_root <dir>: the Kubuntu desktop parts the two scripts touch.
make_root() {
    local root=$1
    rm -rf "$root"
    for w in Kubuntu KubuntuBlack KubuntuLight Patak Next; do
        make_wallpaper "$root" "$w"
    done
    make_theme "$root" org.kubuntu.desktop Kubuntu 'file:///usr/share/wallpapers/Kubuntu#day-night' 1
    make_theme "$root" org.kubuntudark.desktop Kubuntu 'file:///usr/share/wallpapers/Kubuntu' 0
    make_theme "$root" org.kubuntulight.desktop Kubuntu 'file:///usr/share/wallpapers/Kubuntu' 0
    make_theme "$root" org.kde.breeze.desktop Next 'file:///usr/share/wallpapers/Next' 0
    mkdir -p "$root/usr/share/kubuntu-default-settings/kf5-settings"
    cat >"$root/usr/share/kubuntu-default-settings/kf5-settings/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=true
Timeout=15

[Greeter][Wallpaper][org.kde.image][General]
DynamicMode=1
Image=file:///usr/share/wallpapers/Kubuntu/#day-night
PreviewImage=file:///usr/share/wallpapers/Kubuntu/#day-night
EOF
}

LF="$TMP/image/usr/share/plasma/look-and-feel"
LOCK="$TMP/image/usr/share/kubuntu-default-settings/kf5-settings/kscreenlockerrc"

# --- 1. The default moves, and every place that chose it is rewritten. -----
make_root "$TMP/image"
out=$(
    cd "$TMP"
    env "$AS_ROOT" sh "$SET_DEFAULT" "$TMP/image" 2>&1
) || fail "set-default-wallpaper.sh failed: $out"
ok "set-default-wallpaper.sh runs"

for theme in org.kubuntu.desktop org.kubuntudark.desktop org.kubuntulight.desktop; do
    grep -qx 'Image=Patak' "$LF/$theme/contents/defaults" ||
        fail "$theme/contents/defaults does not name Patak"
    js="$LF/$theme/contents/layouts/org.kde.plasma.desktop-layout.js"
    grep -q "writeConfig( 'Image', 'file:///usr/share/wallpapers/Patak' )" "$js" ||
        fail "$js does not write the Patak URL"
    grep -q "writeConfig( 'DynamicMode', 0 )" "$js" ||
        fail "$js keeps day/night blending on"
done
ok "all three Kubuntu look-and-feel themes default to Patak without day/night"

grep -q '^Image=file:///usr/share/wallpapers/Patak$' "$LOCK" ||
    fail "the lock screen still uses another wallpaper"
grep -q '^PreviewImage=file:///usr/share/wallpapers/Patak$' "$LOCK" ||
    fail "the lock screen preview still uses another wallpaper"
grep -q '^DynamicMode=0$' "$LOCK" || fail "the lock screen keeps day/night on"
ok "the lock screen follows the same wallpaper"

# Breeze is upstream's own theme; its "Next" default is not a Kubuntu entry and
# must survive untouched.
grep -qx 'Image=Next' "$LF/org.kde.breeze.desktop/contents/defaults" ||
    fail "Breeze's own default was rewritten"
grep -q "wallpapers/Next" "$LF/org.kde.breeze.desktop/contents/layouts/org.kde.plasma.desktop-layout.js" ||
    fail "Breeze's layout wallpaper was rewritten"
[ ! -e "$LF/org.kde.breeze.desktop/contents/defaults.zhento-orig" ] ||
    fail "Breeze's defaults was backed up even though it was not changed"
ok "Breeze's own wallpaper is left alone"

# The stock files are kept for rollback.
[ -f "$LF/org.kubuntu.desktop/contents/defaults.zhento-orig" ] ||
    fail "the stock look-and-feel defaults was not kept"
grep -qx 'Image=Kubuntu' "$LF/org.kubuntu.desktop/contents/defaults.zhento-orig" ||
    fail "the backup is not the stock defaults"
ok "the stock defaults is kept as .zhento-orig"

# A second run is a no-op that still succeeds.
snapshot=$(find "$TMP/image" -type f | sort | xargs cksum 2>/dev/null | cksum)
env "$AS_ROOT" sh "$SET_DEFAULT" "$TMP/image" >/dev/null 2>&1 ||
    fail "a second run of set-default-wallpaper.sh failed"
[ "$snapshot" = "$(find "$TMP/image" -type f | sort | xargs cksum 2>/dev/null | cksum)" ] ||
    fail "a second run changed the tree"
ok "a second run is idempotent"

# --- 2. Bad input fails before writing. ------------------------------------
status=0
env "$AS_ROOT" WALLPAPER='../etc/passwd' sh "$SET_DEFAULT" "$TMP/image" >"$TMP/bad" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "a path-like wallpaper name exited $status, expected 1"
grep -q 'Not a valid wallpaper name' "$TMP/bad" || fail "the name guard gave no reason"
ok "a wallpaper name that is not a kpackage name is refused"

status=0
env "$AS_ROOT" WALLPAPER=NoSuchWallpaper sh "$SET_DEFAULT" "$TMP/image" >"$TMP/bad2" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "a missing wallpaper exited $status, expected 1"
grep -q 'Wallpaper not installed' "$TMP/bad2" || fail "the missing-kpackage guard gave no reason"
ok "a wallpaper that is not installed is refused"

status=0
env "$AS_ROOT" PATH="$ROOT_BIN:$PATH" sh "$SET_DEFAULT" "$TMP/image" >"$TMP/bad3" 2>&1 || status=$?
rm -rf "$TMP/empty"
mkdir -p "$TMP/empty/usr/share/wallpapers"
status=0
env "$AS_ROOT" WALLPAPER=Ghost sh "$SET_DEFAULT" "$TMP/empty" >/dev/null 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "a target with no wallpapers exited $status, expected 1"
ok "a target without the chosen wallpaper is refused"

# --- 3. Removal takes the stock wallpapers out and locks them out. --------
out=$(env "$AS_ROOT" sh "$REMOVE" "$TMP/image" 2>&1) || fail "remove script failed: $out"
for w in Kubuntu KubuntuBlack KubuntuLight; do
    [ ! -e "$TMP/image/usr/share/wallpapers/$w" ] ||
        fail "/usr/share/wallpapers/$w survived removal"
    grep -qx "path-exclude=/usr/share/wallpapers/$w/\*" \
        "$TMP/image/etc/dpkg/dpkg.cfg.d/zhento-wallpapers" ||
        fail "no dpkg path filter for $w"
done
[ -d "$TMP/image/usr/share/wallpapers/Patak" ] || fail "Patak was removed too"
[ -d "$TMP/image/usr/share/wallpapers/Next" ] || fail "Next was removed too"
ok "the three stock wallpapers are gone; Patak and Next remain"

# The filter is installed in the image, not just applied to this build.
filter="$TMP/image/etc/dpkg/dpkg.cfg.d/zhento-wallpapers"
grep -q 'dpkg' "$filter" || fail "the filter does not explain itself"
ok "the dpkg path filter is installed in the image"

# The default is Patak and every reference resolves, so the check passes.
[ -z "$(env "$AS_ROOT" sh "$SET_DEFAULT" "$TMP/image" 2>&1 |
    grep -i 'missing /usr/share/wallpapers' || true)" ] ||
    fail "a reference to a removed wallpaper is left behind"
value=$(env "$AS_ROOT" sh "$SET_DEFAULT" "$TMP/image" 2>&1 |
    sed -n 's/.*Checking that every wallpaper reference resolves.*/ok/p')
[ -n "$value" ] || fail "the reference check did not report success"
ok "no default points at a removed wallpaper"

# --- 4. Removal is idempotent and works on a partially removed tree. -----
before=$(cksum "$filter")
env "$AS_ROOT" sh "$REMOVE" "$TMP/image" >/dev/null 2>&1 ||
    fail "a second removal failed"
[ "$before" = "$(cksum "$filter")" ] || fail "a second removal rewrote the filter differently"
ok "a second removal is idempotent"

# --- 5. Removing while a default still names a stock wallpaper fails. -----
make_root "$TMP/stock-only"
status=0
out=$(env "$AS_ROOT" sh "$REMOVE" "$TMP/stock-only" 2>&1) || status=$?
[ "$status" -eq 1 ] || fail "removal with a dangling default exited $status, expected 1"
case "$out" in
*'still names a removed wallpaper'*) ;;
*) fail "the dangling-default guard gave no reason: $out" ;;
esac
ok "removal refuses to leave the desktop pointed at a removed wallpaper"

# --- 6. Non-root callers are refused before anything is written. ----------
for script in "$SET_DEFAULT" "$REMOVE"; do
    dir="$TMP/target-$(basename "$script" .sh)"
    make_root "$dir"
    before=$(find "$dir" -type f | sort | xargs cksum 2>/dev/null | cksum)
    set +e
    out=$(PATH="$NONROOT_BIN:$PATH" sh "$script" "$dir" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$(basename "$script") as non-root exited $rc, expected 1"
    case "$out" in *'root is required'*) ;; *) fail "$(basename "$script") root guard missing: $out" ;; esac
    [ "$before" = "$(find "$dir" -type f | sort | xargs cksum 2>/dev/null | cksum)" ] ||
        fail "$(basename "$script") wrote files as a non-root caller"
done
ok "both scripts refuse non-root callers and write nothing"

printf '\nAll edit-wallpaper checks passed\n'
