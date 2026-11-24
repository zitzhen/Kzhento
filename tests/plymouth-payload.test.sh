#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for the Kzhento boot theme payload in edit-plymouth/:
#
#   - the theme file names a module, points its ImageDir at the directory the
#     installer fills, and declares the animation that module draws
#   - every asset the theme names as its own is written by edit-plymouth.sh
#   - the theme does not depend on the stock "spinner" theme's throbber frames:
#     those are the frames of that theme's own script, and two-step would never
#     draw them (they used to be copied in and nothing read them)
#   - the default.plymouth alternative is set by the installer and by
#     select-theme.sh to the same theme the payload installs
#
# Nothing is rendered and no logo is needed: this checks the contract between
# the .plymouth file and the installer, which is what a build can get wrong
# while render.py keeps producing perfectly good PNGs.
#
# Usage: bash tests/plymouth-payload.test.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
THEME_FILE="$REPO_DIR/edit-plymouth/plymouth/minimal.plymouth"
INSTALL_SCRIPT="$REPO_DIR/edit-plymouth/edit-plymouth.sh"
SELECT_SCRIPT="$REPO_DIR/edit-plymouth/select-theme.sh"
THEME_NAME=minimal
IMAGE_DIR="/usr/share/plymouth/themes/$THEME_NAME"
THEME_PATH="$IMAGE_DIR/minimal.plymouth"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

for f in "$THEME_FILE" "$INSTALL_SCRIPT" "$SELECT_SCRIPT"; do
    [ -f "$f" ] || fail "missing input: $f"
done

# ini <section> <key> [default]: value of key in section, or the default when
# the key is absent. Repeated keys are not expected here, so the first match
# wins. An absent key with no default is a failure, not an empty string.
ini() {
    local value
    value=$(awk -v section="[$1]" -v key="$2" '
        /^\[/ { in_section = ($0 == section); next }
        in_section && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
    ' "$THEME_FILE")
    if [ -z "$value" ]; then
        [ "$#" -ge 3 ] || fail "theme file has no $2 in section [$1]: $THEME_FILE"
        value=$3
    fi
    printf '%s\n' "$value"
}

module=$(ini "Plymouth Theme" ModuleName)
case "$module" in
two-step) ok "theme uses the two-step module" ;;
*) fail "theme uses module '$module'; the Kzhento artwork is prepared for two-step" ;;
esac

# Keys only; the file's comments explain the stock frames and must not trip the
# checks below.
keys=$(sed 's/^[[:space:]]*[#;].*//' "$THEME_FILE" | grep -v '^[[:space:]]*$')

image_dir=$(ini "$module" ImageDir)
[ "$image_dir" = "$IMAGE_DIR" ] ||
    fail "ImageDir is '$image_dir', expected $IMAGE_DIR (the directory the installer fills)"
grep -qF "THEME_DIR=\"\$root$IMAGE_DIR\"" "$INSTALL_SCRIPT" ||
    fail "installer does not write into ImageDir=$image_dir"
ok "ImageDir matches the directory edit-plymouth.sh installs into"

watermark=$(ini "$module" WatermarkImage watermark.png)
case "$watermark" in
*/*) fail "WatermarkImage '$watermark' is a path; two-step wants a name in ImageDir" ;;
esac
grep -qF "\"\$THEME_DIR/$watermark\"" "$INSTALL_SCRIPT" ||
    fail "theme draws watermark '$watermark' but edit-plymouth.sh never installs it"
ok "theme watermark $watermark is installed"

# The animation: two-step draws animation-NN.png from AnimationDir, so whatever
# the theme names as its animation is the frame the build has to provide.
animation=$(ini "$module" AnimationFile animation-0001.png)
animation_dir=$(ini "$module" AnimationDir "$image_dir")
[ "$animation_dir" = "$image_dir" ] ||
    fail "AnimationDir is '$animation_dir' but ImageDir is '$image_dir'; the installer only fills ImageDir"
frame=${animation##*/}
[ "$frame" != "$animation" ] || frame=$animation
case "$frame" in
animation-*.png) ;;
*) fail "AnimationFile is '$animation', expected an animation-NN.png frame" ;;
esac
grep -qF "\"\$THEME_DIR/$frame\"" "$INSTALL_SCRIPT" ||
    fail "theme draws $frame but edit-plymouth.sh never installs it"
ok "theme animation $frame is installed"

# The stock frames are the "spinner" theme's own script assets. The installer
# must not copy them in, and nothing in the payload may reference them, or the
# theme would appear to have a spinner it never draws.
grep -q 'throbber-' <<<"$keys" &&
    fail "theme file references throbber-*.png; two-step never draws those frames"
copied=$(sed -n '/^for asset in /,/^done$/p' "$INSTALL_SCRIPT")
grep -q 'throbber-\*\.png' <<<"$copied" ||
    fail "installer no longer skips the stock throbber-*.png frames when copying ImageDir assets"
ok "stock throbber frames are not carried into the Kzhento theme"

# One theme, one name: the alternative must resolve to the payload's file.
[ "$THEME_PATH" = "$image_dir/minimal.plymouth" ] || fail "unexpected theme path: $THEME_PATH"
grep -qF "$THEME_PATH" "$INSTALL_SCRIPT" ||
    fail "edit-plymouth.sh does not register $THEME_PATH as default.plymouth"
grep -qF "$THEME_PATH" "$SELECT_SCRIPT" ||
    fail "select-theme.sh does not point default.plymouth at $THEME_PATH"
ok "default.plymouth resolves to $THEME_PATH"

# The machine's own logo has to stay on screen. two-step paints the firmware
# image (/sys/firmware/acpi/bgrt/image) only when UseFirmwareBackground is true;
# the module defaults it off, so a theme that omits the key silently drops the
# OEM logo and shows a plain black background instead. The stock Kubuntu theme
# sets it in [two-step] and in every phase section, and the branded theme has to
# keep doing the same.
for section in "$module" boot-up shutdown reboot; do
    value=$(ini "$section" UseFirmwareBackground "")
    [ "$value" = "true" ] ||
        fail "UseFirmwareBackground is '${value:-<unset>}' in [$section]; the firmware (OEM) logo would not be drawn"
done
ok "firmware background is enabled in every phase, so the OEM logo stays"

value=$(ini "$module" DialogClearsFirmwareBackground "")
[ "$value" = "false" ] ||
    fail "DialogClearsFirmwareBackground is '${value:-<unset>}'; a password prompt would wipe the OEM logo"
ok "the firmware background is not cleared by dialogs"

printf '\nplymouth payload checks passed\n'
