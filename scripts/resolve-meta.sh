#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Resolve the version, tag, base ISO and its cache key for one CI job.
#
# This is deliberately a script rather than a `meta` job whose outputs the other
# jobs consume. When a workflow run is retried with "Re-run failed jobs", only
# the failed job runs again and the outputs of jobs that already succeeded are
# not injected into it - a release job that read `needs.meta.outputs.version`
# would come back with an empty version. Recomputing the same values from the
# same inputs keeps a retried job self-sufficient.
#
# Usage (in a workflow step):
#   ./scripts/resolve-meta.sh
#
# Inputs (environment):
#   EVENT_NAME      github.event_name
#   REF_NAME        github.ref_name (the tag on a tag push)
#   INPUT_VERSION   inputs.version (manual dispatch only)
#   INPUT_BASE_URL  inputs.base_iso_url (manual dispatch only)
#   INPUT_BASE_SHA  inputs.base_iso_sha256 (manual dispatch only)
#   DEFAULT_BASE_ISO_URL  repository default, from the workflow env block
#   GITHUB_OUTPUT   when set, the values are appended as step outputs
#
# Outputs: version, tag, base_url, base_sha, iso_key (also exported when
# GITHUB_ENV is set, so later steps can use them without repeating the parse).

set -euo pipefail

die() {
    printf 'XX  %s\n' "$*" >&2
    exit 1
}

event=${EVENT_NAME:-}
ref=${REF_NAME:-}

if [ "$event" = "workflow_dispatch" ]; then
    version=${INPUT_VERSION:-}
    base_url=${INPUT_BASE_URL:-}
    base_sha=${INPUT_BASE_SHA:-}
else
    # A tag push carries the version in the ref; anything else has no version.
    version=${ref#v}
    base_url=${DEFAULT_BASE_ISO_URL:-}
    base_sha=""
fi

[ -n "$version" ] || die "Version is empty (event=${event} ref=${ref})"
[ -n "$base_url" ] || die "Base ISO URL is empty"
case "$version" in
v*) die "Version must not carry the leading v: ${version}" ;;
esac

# Same key on both code paths for the same image: the tag push has no sha256
# input, so an unset checksum is part of the key rather than a different key.
iso_key="base-iso-$(printf '%s|%s' "$base_url" "$base_sha" | sha256sum | cut -c1-16)"

printf 'version  : %s\n' "$version"
printf 'tag      : v%s\n' "$version"
printf 'base ISO : %s\n' "$base_url"
printf 'base sha : %s\n' "${base_sha:-<unverified>}"
printf 'cache key: %s\n' "$iso_key"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=${version}"
        echo "tag=v${version}"
        echo "base_url=${base_url}"
        echo "base_sha=${base_sha}"
        echo "iso_key=${iso_key}"
        echo "artifact=iso-${version}"
    } >>"$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "VERSION=${version}"
        echo "TAG=v${version}"
        echo "BASE_ISO_URL_RESOLVED=${base_url}"
        echo "BASE_ISO_SHA=${base_sha}"
        echo "ISO_ARTIFACT=iso-${version}"
    } >>"$GITHUB_ENV"
fi
