#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for edit-notification/edit-welcome.sh, the step that replaces the
# first page of the Welcome Center.
#
# The page it installs is QML shipped in this repository
# (edit-notification/plasma-welcome/01-Kzhento.qml), so this suite checks two
# different things, and both are failure modes that only show up on screen:
#
#   - the payload is valid QML: a syntax error here is a blank or missing page
#     at first login, not a build failure
#   - the payload says K-Zhento and no longer says Kubuntu, and it does not
#     still point at kubuntu.org
#   - the installer replaces the stock page in place, keeps it as
#     <name>.zhento-orig, installs the rendered wordmark next to it, and leaves
#     no second *.qml that plasma-welcome would enumerate as another page
#   - a target without plasma-welcome is a skip, not a failure
#   - a second run does not overwrite the stock backup with our own page
#
# qmllint is used when present; it is what catches a typo in the QML, which is
# the one class of mistake no shell check would see.
#
# Usage: bash tests/edit-welcome.test.sh
#
# Environment:
#   LOGO_DIR   directory holding kzhento_transparent.png (default: <repo>/logo)

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_DIR/edit-notification/edit-welcome.sh"
PAGE="$REPO_DIR/edit-notification/plasma-welcome/01-Kzhento.qml"
LOGO_DIR=${LOGO_DIR:-"$REPO_DIR/logo"}

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

for f in "$SCRIPT" "$PAGE"; do
    [ -f "$f" ] || fail "missing input: $f"
done
[ -x "$SCRIPT" ] || fail "not executable: $SCRIPT"

if [ ! -f "$LOGO_DIR/kzhento_transparent.png" ]; then
    printf '..  no logo at %s; the artwork is downloaded, not committed\n' \
        "$LOGO_DIR/kzhento_transparent.png"
    printf '\nedit-welcome checks skipped\n'
    exit 0
fi
python3 -c 'import PIL' 2>/dev/null || {
    printf '..  Pillow is not installed\n'
    exit 0
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Mock id for the root guard.
ROOT_BIN="$TMP/root-bin"
NONROOT_BIN="$TMP/nonroot-bin"
mkdir -p "$ROOT_BIN" "$NONROOT_BIN"
printf '#!/bin/sh\necho 0\n' >"$ROOT_BIN/id"
printf '#!/bin/sh\necho 1000\n' >"$NONROOT_BIN/id"
chmod +x "$ROOT_BIN/id" "$NONROOT_BIN/id"

# --- 1. The payload is valid QML. ---------------------------------------
#
# qmllint resolves the org.kde.plasma.welcome import from the host, which only
# exists where plasma-welcome is installed; on a runner without it the import
# fails for every QML file. So a clean parse is what is required, and a
# syntax error is what must not pass.
if command -v qmllint >/dev/null 2>&1; then
    out=$(qmllint "$PAGE" 2>&1) || true
    case "$out" in
    *"Expected token"* | *"expected token"* | *"Syntax error"* | *"syntax error"*)
        fail "the page payload does not parse: $out"
        ;;
    esac
    # Sanity-check that qmllint does report a broken file, so a silent pass on
    # this runner does not hide a real syntax error.
    printf 'import QtQuick\nItem { property int x: }\n' >"$TMP/broken.qml"
    broken=$(qmllint "$TMP/broken.qml" 2>&1 || true)
    [ -n "$broken" ] ||
        fail "qmllint reported nothing for a file that cannot parse; the check above is meaningless"
    ok "the page payload parses as QML (and qmllint is shown to report errors)"
else
    printf '..  qmllint not installed, skipping the QML parse check\n'
fi

# --- 2. The payload is rebranded. ---------------------------------------
grep -q 'K-Zhento' "$PAGE" || fail "the payload does not mention K-Zhento"
grep -q 'zitzhen.cn' "$PAGE" || fail "the payload does not link to zitzhen.cn"
if grep -qi 'kubuntu\.org' "$PAGE"; then
    fail "the payload still links to kubuntu.org"
fi
# The stock images are Kubuntu artwork; the page must not reference them any
# more, or the Kubuntu wordmark and Donate badge come back on screen.
for asset in kubuntu_tour.svg kubuntu_donate.svg; do
    if grep -q "$asset" "$PAGE"; then
        fail "the payload still draws the stock artwork: $asset"
    fi
done
ok "the payload is K-Zhento content with the stock artwork gone"

# The heading and the body are the two strings that were hard-coded in the stock
# page. They are what a user actually reads, so they are asserted by substring.
grep -q 'Welcome to K-Zhento' "$PAGE" || fail "the page heading was not rebranded"
grep -q 'K-Zhento is free software' "$PAGE" || fail "the page body was not rebranded"
ok "the heading and body text are the K-Zhento ones"

# --- 3. The installer replaces the page. --------------------------------
make_root() {
    local root=$1
    mkdir -p "$root/usr/share/plasma/plasma-welcome/extra-pages"
    cat >"$root/usr/share/plasma/plasma-welcome/extra-pages/01-Kubuntu.qml" <<'QML'
GenericPage {
    heading: i18nc("@info:window", "Welcome to Kubuntu | Friendly Computing")
}
QML
}

root="$TMP/image"
make_root "$root"
PAGES="$root/usr/share/plasma/plasma-welcome/extra-pages"
PATH="$ROOT_BIN:$PATH" LOGO_DIR="$LOGO_DIR" sh "$SCRIPT" "$root" >"$TMP/log" 2>&1 ||
    fail "installer failed: $(cat "$TMP/log")"

[ -f "$PAGES/01-Kubuntu.qml" ] || fail "the page was not installed at its stock name"
grep -q 'Welcome to K-Zhento' "$PAGES/01-Kubuntu.qml" ||
    fail "the installed page is not the K-Zhento one"
[ -f "$PAGES/01-Kubuntu.qml.zhento-orig" ] ||
    fail "the stock page was not kept as .zhento-orig"
grep -q 'Welcome to Kubuntu' "$PAGES/01-Kubuntu.qml.zhento-orig" ||
    fail "the backup is not the stock page"
[ -f "$PAGES/kzhento-logo.png" ] ||
    fail "the wordmark image was not installed next to the page"
ok "installs the page in place, keeps the stock one, and installs the wordmark"

# No second page: plasma-welcome enumerates *.qml, so an extra one would show up
# as another page in the tour.
count=$(find "$PAGES" -maxdepth 1 -name '*.qml' | wc -l)
[ "$count" -eq 1 ] || fail "$count .qml pages in $PAGES, expected exactly 1"
ok "exactly one page in extra-pages, so the tour does not gain a page"

# The image is the logo, not a placeholder: it has ink and it is wide and flat
# (the stock page draws it at a fixed 5:1-ish aspect inside a row).
python3 - "$PAGES/kzhento-logo.png" <<'PY' || exit 1
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGBA")
w, h = im.size
problems = []
if w < 500:
    problems.append(f"only {w} px wide")
if not 2 <= w / h <= 5:
    problems.append(f"aspect ratio {w / h:.2f}, not the wordmark's")
ink = sum(1 for p in im.get_flattened_data() if p[3] > 200)
if ink < (w * h) // 50:
    problems.append(f"only {ink} opaque pixels")
if problems:
    print("  " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"ok - the wordmark is {w}x{h} with {ink} ink pixels")
PY
ok "the installed wordmark is the rendered logo"

# --- 4. Targets without plasma-welcome are skipped. ---------------------
bare="$TMP/bare"
mkdir -p "$bare/usr/share"
PATH="$ROOT_BIN:$PATH" LOGO_DIR="$LOGO_DIR" sh "$SCRIPT" "$bare" >"$TMP/log2" 2>&1 ||
    fail "a target without plasma-welcome failed instead of skipping"
grep -q 'skipping the Welcome Center page' "$TMP/log2" ||
    fail "the skip was not reported: $(cat "$TMP/log2")"
ok "a target without plasma-welcome is skipped with a reason"

# --- 5. A second run keeps the stock backup. ---------------------------
orig_sum=$(cksum "$PAGES/01-Kubuntu.qml.zhento-orig")
PATH="$ROOT_BIN:$PATH" LOGO_DIR="$LOGO_DIR" sh "$SCRIPT" "$root" >/dev/null 2>&1 ||
    fail "the second run failed"
[ "$orig_sum" = "$(cksum "$PAGES/01-Kubuntu.qml.zhento-orig")" ] ||
    fail "the stock backup was replaced by a later run"
grep -q 'Welcome to Kubuntu' "$PAGES/01-Kubuntu.qml.zhento-orig" ||
    fail "the backup is no longer the stock page"
ok "a second run keeps the stock page as the backup"

# --- 6. Non-root callers are refused. ----------------------------------
before=$(find "$root" -type f | sort | xargs cksum 2>/dev/null | cksum)
set +e
out=$(PATH="$NONROOT_BIN:$PATH" LOGO_DIR="$LOGO_DIR" sh "$SCRIPT" "$root" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "non-root call exited $rc, expected 1"
case "$out" in *'root is required'*) ;; *) fail "root guard missing: $out" ;; esac
[ "$before" = "$(find "$root" -type f | sort | xargs cksum 2>/dev/null | cksum)" ] ||
    fail "the script wrote files as a non-root caller"
ok "refuses to run without root, without writing anything"

printf '\nAll edit-welcome checks passed\n'
