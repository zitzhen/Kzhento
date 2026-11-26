#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for scripts/resolve-meta.sh: the version/tag/base ISO resolution that
# each build-iso job performs for itself.
#
# The behaviour worth pinning down is the "Re-run failed jobs" case. A retried
# job does not receive the outputs of jobs that already succeeded, so the
# resolution must be a pure function of the event inputs - no state carried
# between jobs. These tests drive the script with only env vars and check that
# the same inputs give the same cache key on both the tag and dispatch paths.
#
# No network, no root, no GitHub: outputs go to a temp file.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_DIR/scripts/resolve-meta.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

[ -x "$SCRIPT" ] || fail "not executable: $SCRIPT"

# run_meta <outfile> <VAR=value>... : run the script with a clean environment
# plus exactly the given variables, so a test cannot pass because the developer
# happened to export something.
run_meta() {
    local out=$1
    shift
    : >"$out"
    env -i PATH=/usr/bin:/bin HOME="$TMP" \
        GITHUB_OUTPUT="$out" "$@" "$SCRIPT" >"$TMP/stdout" 2>"$TMP/stderr"
}

field() {
    sed -n "s/^$1=//p" "$2"
}

# --- manual dispatch: everything comes from the inputs ----------------------
URL="https://example.invalid/base-26.04.1.iso"
SHA="1111111111111111111111111111111111111111111111111111111111111111"
run_meta "$TMP/dispatch.out" \
    EVENT_NAME=workflow_dispatch REF_NAME=main \
    INPUT_VERSION=0.1.0 INPUT_BASE_URL="$URL" INPUT_BASE_SHA="$SHA"

[ "$(field version "$TMP/dispatch.out")" = "0.1.0" ] || fail "dispatch: version"
[ "$(field tag "$TMP/dispatch.out")" = "v0.1.0" ] || fail "dispatch: tag"
[ "$(field base_url "$TMP/dispatch.out")" = "$URL" ] || fail "dispatch: base_url"
[ "$(field base_sha "$TMP/dispatch.out")" = "$SHA" ] || fail "dispatch: base_sha"
[ "$(field artifact "$TMP/dispatch.out")" = "iso-0.1.0" ] || fail "dispatch: artifact"
ok "manual dispatch resolves from the inputs"

# --- tag push: version from the ref, default base ISO, no checksum ----------
run_meta "$TMP/tag.out" \
    EVENT_NAME=push REF_NAME=v0.2.0 \
    DEFAULT_BASE_ISO_URL="$URL"

[ "$(field version "$TMP/tag.out")" = "0.2.0" ] || fail "tag: version from ref"
[ "$(field tag "$TMP/tag.out")" = "v0.2.0" ] || fail "tag: tag"
[ "$(field base_url "$TMP/tag.out")" = "$URL" ] || fail "tag: default base url"
[ "$(field base_sha "$TMP/tag.out")" = "" ] || fail "tag: base_sha must stay empty"
ok "a tag push derives the version from the ref"

# --- the same image gives the same cache key on both paths ------------------
# A tag build and a dispatch pinned to the same URL and checksum must share the
# base ISO cache entry; otherwise every release re-downloads 5G.
run_meta "$TMP/tag-same.out" \
    EVENT_NAME=workflow_dispatch REF_NAME=main \
    INPUT_VERSION=0.1.0 INPUT_BASE_URL="$URL" INPUT_BASE_SHA="$SHA"

tag_key=$(field iso_key "$TMP/dispatch.out")
same_key=$(field iso_key "$TMP/tag-same.out")
[ "$tag_key" = "$same_key" ] || fail "cache key is not deterministic: $tag_key != $same_key"
case "$tag_key" in
base-iso-*) ;;
*) fail "unexpected cache key shape: $tag_key" ;;
esac
ok "cache key is a pure function of URL + checksum ($tag_key)"

run_meta "$TMP/other.out" \
    EVENT_NAME=workflow_dispatch REF_NAME=main \
    INPUT_VERSION=0.1.0 INPUT_BASE_URL="$URL" \
    INPUT_BASE_SHA="2222222222222222222222222222222222222222222222222222222222222222"
[ "$(field iso_key "$TMP/other.out")" != "$tag_key" ] ||
    fail "a different checksum must produce a different cache key"
ok "a different checksum gets its own cache key"

# --- failure paths ---------------------------------------------------------
if run_meta "$TMP/empty.out" EVENT_NAME=workflow_dispatch REF_NAME=main INPUT_VERSION=; then
    fail "an empty version must fail the job, not silently build 0.1.0"
fi
grep -q 'Version is empty' "$TMP/stderr" || fail "empty version: unclear error"
ok "an empty version fails loudly"

if run_meta "$TMP/v.out" \
    EVENT_NAME=workflow_dispatch REF_NAME=main \
    INPUT_VERSION=v0.1.0 INPUT_BASE_URL="$URL"; then
    fail "a version with the leading v must be rejected"
fi
grep -q 'leading v' "$TMP/stderr" || fail "leading v: unclear error"
ok "a version with the leading v is rejected"

if run_meta "$TMP/nourl.out" EVENT_NAME=workflow_dispatch REF_NAME=main INPUT_VERSION=0.1.0; then
    fail "a missing base ISO URL must fail the job"
fi
ok "a missing base ISO URL fails loudly"

# GITHUB_ENV is only written when the path is set; without it the script must
# still succeed (local use) rather than fail on an unbound variable.
if ! env -i PATH=/usr/bin:/bin \
    EVENT_NAME=workflow_dispatch REF_NAME=main \
    INPUT_VERSION=0.1.0 INPUT_BASE_URL="$URL" \
    "$SCRIPT" >/dev/null 2>"$TMP/stderr"; then
    cat "$TMP/stderr" >&2
    fail "the script must work outside Actions (no GITHUB_OUTPUT/GITHUB_ENV)"
fi
ok "runs outside Actions without GITHUB_OUTPUT or GITHUB_ENV"

printf '\nAll resolve-meta checks passed\n'
