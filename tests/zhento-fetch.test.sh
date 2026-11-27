#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for install-app/lib/zhento-fetch.sh, the retrying download wrapper used
# by the scripts that pull preinstalled apps from upstream releases.
#
# The build downloads those artifacts inside a ~15 minute ISO build, so a
# transient CDN failure must not throw the image away - but a genuinely missing
# artifact must still fail fast instead of burning retries. Both directions are
# asserted here with a stubbed curl: no network, no root.
#
# The stub also pins down a subtlety that broke an earlier draft: the exit
# status has to be captured explicitly, because "$?" read after an `if` is the
# status of the `if`, not of curl. The "HTTP error is not retried" case is what
# catches that mistake.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$REPO_DIR/install-app/lib/zhento-fetch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

[ -f "$HELPER" ] || fail "missing helper: $HELPER"

# The helper must not be picked up as an install script: build.sh runs every
# install-app/*.sh, so a helper in install-app/ itself would be executed.
if [ -e "$REPO_DIR/install-app/zhento-fetch.sh" ]; then
    fail "helper must not live directly in install-app/ (build.sh would run it)"
fi
ok "helper is outside the install-app/*.sh glob"

# run_case <name> <curl-exit-sequence> : drives the helper with a stubbed curl
# that fails the given number of times before succeeding.
run_case() {
    local name=$1
    local fail_times=$2
    local body="$TMP/$name.sh"

    cat >"$body" <<EOF
set -e
. "$HELPER"
COUNT=0
curl() {
    COUNT=\$((COUNT + 1))
    if [ "\$COUNT" -le $fail_times ]; then
        return \${STUB_RC:-56}
    fi
    prev=""
    for a in "\$@"; do
        [ "\$prev" = "-o" ] && printf 'payload\n' > "\$a"
        prev=\$a
    done
    return 0
}
ZHENTO_FETCH_ATTEMPTS=\${STUB_ATTEMPTS:-3}
ZHENTO_FETCH_DELAY=0
export COUNT
if zhento_fetch "http://example.invalid/asset" "$TMP/$name.out"; then
    echo "RESULT=success ATTEMPTS=\$COUNT"
else
    echo "RESULT=failure ATTEMPTS=\$COUNT"
fi
EOF
    sh "$body" 2>"$TMP/$name.err"
}

# --- transient failure, then success -------------------------------------
out=$(run_case transient 2)
case "$out" in
*"RESULT=success"*) ;;
*) fail "transient failures should end in success: $out" ;;
esac
case "$out" in
*"ATTEMPTS=3"*) ;;
*) fail "expected 3 attempts (2 failures + success), got: $out" ;;
esac
[ "$(cat "$TMP/transient.out")" = "payload" ] || fail "transient: file not written"
ok "retries a transient failure and then succeeds"

# --- HTTP 404 (curl rc 22) must not be retried ---------------------------
out=$(STUB_RC=22 STUB_ATTEMPTS=5 run_case http404 5)
case "$out" in
*"RESULT=failure ATTEMPTS=1"*) ;;
*) fail "an HTTP error must fail on the first attempt, got: $out" ;;
esac
grep -q 'not retried' "$TMP/http404.err" ||
    fail "an HTTP error should say it was not retried"
ok "does not retry an HTTP error (fails in one attempt)"

# --- exhausted retries ---------------------------------------------------
out=$(STUB_ATTEMPTS=3 run_case exhausted 99)
case "$out" in
*"RESULT=failure ATTEMPTS=3"*) ;;
*) fail "expected exactly 3 attempts before giving up, got: $out" ;;
esac
grep -q 'after 3 attempts' "$TMP/exhausted.err" ||
    fail "giving up should name the attempt count"
ok "gives up after the configured number of attempts"

# --- argument validation -------------------------------------------------
cat >"$TMP/empty.sh" <<EOF
set -e
. "$HELPER"
if zhento_fetch "" "$TMP/x.out"; then echo "RESULT=success"; else echo "RESULT=failure"; fi
EOF
out=$(sh "$TMP/empty.sh" 2>&1)
case "$out" in
*"RESULT=failure"*) ;;
*) fail "an empty URL must be rejected: $out" ;;
esac
ok "rejects an empty URL"

# --- the install scripts actually use the helper -------------------------
for s in Innstaller.sh innstaller.sh calamares-settings-zhento.sh; do
    [ -f "$REPO_DIR/install-app/$s" ] || continue
    grep -q 'lib/zhento-fetch.sh' "$REPO_DIR/install-app/$s" ||
        fail "$s does not source the download helper"
    if grep -qE '^curl -' "$REPO_DIR/install-app/$s"; then
        fail "$s still calls curl directly instead of zhento_fetch"
    fi
done
ok "the app install scripts download through the helper"

printf '\nAll zhento-fetch checks passed\n'
