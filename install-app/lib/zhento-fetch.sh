# shellcheck shell=sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Shared download helper for install-app/*.sh. Sourced, not executed.
#
# The `shellcheck shell=sh` directive above stands in for a shebang: this file
# is sourced, never run, so it has no interpreter line of its own. Without the
# directive shellcheck cannot tell which dialect to check it against (SC2148).
#
# It lives in install-app/lib/ on purpose: build.sh runs every install-app/*.sh
# as an install script, so a helper placed directly in install-app/ would be
# executed as one.
#
# Why retries: the build downloads each preinstalled app from an external
# release during a ~15 minute ISO build. One transient failure - a 502 from the
# release CDN, a reset connection - used to abort the whole build, the most
# expensive place to fail.
#
# curl's --retry only retries what is worth retrying: connection errors,
# timeouts, and HTTP 408/429/5xx. A 404 is NOT retried by curl, and this helper
# does not retry it either (verified: it fails in about a second). A missing
# asset is a real error - usually a version bump in a sibling project - and
# retrying it only hides the cause behind a delay.
#
# Usage:
#   SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
#   . "$SCRIPT_DIR/lib/zhento-fetch.sh"
#   zhento_fetch <url> <output-file>
#
# Tunable via ZHENTO_FETCH_ATTEMPTS / ZHENTO_FETCH_DELAY so CI can adjust the
# policy without editing every script.

# Guard against double-sourcing.
if [ -z "${ZHENTO_FETCH_LOADED:-}" ]; then
    ZHENTO_FETCH_LOADED=1

    # The loop is on top of curl's own --retry. curl covers a retried request
    # once an HTTP exchange happened; the loop covers an attempt that died
    # before that (DNS, TLS handshake). Both are bounded, so a genuinely
    # broken URL still fails quickly.
    zhento_fetch() {
        url=$1
        out=$2
        attempts=${ZHENTO_FETCH_ATTEMPTS:-3}
        delay=${ZHENTO_FETCH_DELAY:-5}
        n=1

        [ -n "$url" ] || {
            echo "XX  zhento_fetch: empty URL" >&2
            return 2
        }
        [ -n "$out" ] || {
            echo "XX  zhento_fetch: empty output path" >&2
            return 2
        }

        while :; do
            # -f: treat 4xx/5xx as failure instead of saving an error page.
            # -L: releases redirect to a CDN.
            # --retry-connrefused: a refused connection is worth retrying.
            # --max-time: no build may hang on a stalled transfer.
            #
            # The exit status is captured explicitly: "$?" after an `if` sees
            # the status of the `if` itself, not of curl, so testing
            # `if curl ...; then` and then reading $? always yields 0 and the
            # "HTTP error, do not retry" branch below would never trigger.
            rc=0
            curl -fsSL \
                --retry 3 --retry-delay 2 --retry-connrefused \
                --connect-timeout 15 --max-time 300 \
                -o "$out" "$url" || rc=$?

            [ "$rc" -eq 0 ] && return 0

            # curl exit 22 is "HTTP response >= 400": a real answer, not a
            # transport problem, so retrying only delays a failure that will
            # not change.
            if [ "$rc" -eq 22 ]; then
                echo "XX  download failed (HTTP error, not retried): $url" >&2
                return "$rc"
            fi

            if [ "$n" -ge "$attempts" ]; then
                echo "XX  download failed after ${attempts} attempts (curl rc=${rc}): $url" >&2
                return "$rc"
            fi

            echo "!!  download attempt ${n}/${attempts} failed (curl rc=${rc}), retrying in ${delay}s: $url" >&2
            sleep "$delay"
            n=$((n + 1))
        done
    }
fi
