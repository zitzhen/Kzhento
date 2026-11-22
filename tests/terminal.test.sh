#!/usr/bin/env bash
# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tests for the login-shell switch in edit-terminal/edit-terminal.sh and the
# new-account defaults in edit-etc-default-useradd/:
#
#   - both scripts refuse non-root callers without writing anything
#   - edit-terminal.sh rewrites only the intended accounts, keeps system and
#     nologin accounts, backs up existing .zshrc files and installs the payload
#     into /etc/skel and the changed home directories
#   - edit-terminal.sh fails fast on a missing zsh, passwd or .zshrc payload
#   - neither script reports success when its write did not take effect
#   - edit-etc-default-useradd.sh overwrites the target with SHELL=/bin/zsh
#
# No real system files are touched: `id -u` is mocked, every target is a
# temporary directory and the zsh check is driven by a fake binary inside it.
# Usage:
#   bash tests/terminal.test.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TERMINAL="$REPO_DIR/edit-terminal/edit-terminal.sh"
USERADD="$REPO_DIR/edit-etc-default-useradd/edit-etc-default-useradd.sh"
ZSHRC="$REPO_DIR/edit-etc-default-useradd/.zshrc"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok() { printf 'ok - %s\n' "$*"; }

for f in "$TERMINAL" "$USERADD"; do
    [ -f "$f" ] || fail "missing input: $f"
    [ -x "$f" ] || fail "not executable: $f"
done
[ -f "$ZSHRC" ] || fail "missing input: $ZSHRC"

# Mock id so the root guard can be exercised without real privileges.
ROOT_BIN="$TMP/root-bin"
NONROOT_BIN="$TMP/nonroot-bin"
mkdir -p "$ROOT_BIN" "$NONROOT_BIN"
printf '#!/bin/sh\necho 0\n' >"$ROOT_BIN/id"
printf '#!/bin/sh\necho 1000\n' >"$NONROOT_BIN/id"
chmod +x "$ROOT_BIN/id" "$NONROOT_BIN/id"

# Build a fake image root: zsh present, one passwd entry per account class,
# and three home directories (customised / plain / missing).
make_root() {
    local root=$1
    mkdir -p "$root/bin" "$root/etc/skel" "$root/home/oliver" "$root/home/svc"
    cat >"$root/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
systemd-network:x:998:998:systemd Network Management:/:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
oliver:x:1000:1000:Oliver Lin:/home/oliver:/bin/bash
svc:x:1001:1001:Service Account:/home/svc:/usr/sbin/nologin
missing:x:1002:1002:No Home:/home/missing:/bin/bash
toor:x:0:0:Root Alias:/root:/bin/sh
EOF
    printf '#!/bin/sh\n' >"$root/bin/zsh"
    chmod +x "$root/bin/zsh"
}

# 1. Non-root callers are rejected by both scripts without writing anything.
for script in "$TERMINAL" "$USERADD"; do
    root="$TMP/nonroot-$(basename "$script" .sh)"
    make_root "$root"
    before=$(cksum "$root/etc/passwd")
    set +e
    out=$(PATH="$NONROOT_BIN:$PATH" sh "$script" "$root" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$(basename "$script") as non-root exited $rc, expected 1"
    case "$out" in *'No root! exit!'*) ;; *) fail "root guard missing in $script: $out" ;; esac
    [ "$before" = "$(cksum "$root/etc/passwd")" ] || fail "$script modified passwd as non-root"
    [ ! -e "$root/etc/skel/.zshrc" ] || fail "$script installed .zshrc as non-root"
done
ok "both scripts refuse non-root callers and write nothing"

# 2. A missing target tree is rejected without touching the real system.
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$TERMINAL" "$TMP/no-such-root" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "edit-terminal.sh with a missing root exited $rc, expected 1"
case "$out" in *'passwd not found'*) ;; *) fail "missing-passwd diagnostic missing: $out" ;; esac
ok "edit-terminal.sh rejects a target without /etc/passwd"

# 3. A target tree without zsh fails fast, before passwd or skel are touched.
root="$TMP/no-zsh"
make_root "$root"
rm -f "$root/bin/zsh"
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$TERMINAL" "$root" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "edit-terminal.sh without zsh exited $rc, expected 1"
case "$out" in *'zsh is not installed'*) ;; *) fail "missing-zsh diagnostic missing: $out" ;; esac
[ ! -e "$root/etc/skel/.zshrc" ] || fail ".zshrc was installed without zsh present"
grep -q 'oliver:x:1000:1000:Oliver Lin:/home/oliver:/bin/bash' "$root/etc/passwd" ||
    fail "passwd was rewritten without zsh present"
ok "edit-terminal.sh fails fast when zsh is not installed"

# 4. A missing .zshrc payload is reported instead of silently skipped.
root="$TMP/no-payload"
make_root "$root"
set +e
out=$(PATH="$ROOT_BIN:$PATH" ZSHRC_SRC="$TMP/absent.zshrc" \
    sh "$TERMINAL" "$root" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "edit-terminal.sh with a missing payload exited $rc, expected 1"
case "$out" in *'.zshrc not found'*) ;; *) fail "missing-payload diagnostic missing: $out" ;; esac
ok "edit-terminal.sh fails fast when the .zshrc payload is missing"

# 5. The happy path rewrites the right accounts and installs the payload.
root="$TMP/ok"
make_root "$root"
printf 'CUSTOM\n' >"$root/home/oliver/.zshrc"
PATH="$ROOT_BIN:$PATH" sh "$TERMINAL" "$root" >/dev/null

grep -q '^root:x:0:0:root:/root:/bin/zsh$' "$root/etc/passwd" || fail "root shell not switched"
grep -q '^oliver:x:1000:1000:Oliver Lin:/home/oliver:/bin/zsh$' "$root/etc/passwd" ||
    fail "regular account shell not switched"
grep -q '^daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin$' "$root/etc/passwd" ||
    fail "system account was modified"
grep -q '^svc:x:1001:1001:Service Account:/home/svc:/usr/sbin/nologin$' "$root/etc/passwd" ||
    fail "nologin account was switched away from nologin"
grep -q '^missing:x:1002:1002:No Home:/home/missing:/bin/zsh$' "$root/etc/passwd" ||
    fail "account without a home directory is not switched"
grep -q '^nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin$' "$root/etc/passwd" ||
    fail "the system account nobody was switched"
grep -q '^toor:x:0:0:Root Alias:/root:/bin/sh$' "$root/etc/passwd" ||
    fail "a uid-0 alias other than root was switched"
ok "only root and regular accounts on real shells are switched to zsh"

# 6. The payload lands in /etc/skel and in the existing home directories only.
cmp -s "$root/etc/skel/.zshrc" "$ZSHRC" || fail "/etc/skel/.zshrc does not match the payload"
cmp -s "$root/home/oliver/.zshrc" "$ZSHRC" || fail "existing home did not get the payload"
[ ! -e "$root/home/missing/.zshrc" ] || fail ".zshrc written into a non-existent home directory"
ok ".zshrc is installed into /etc/skel and existing home directories"

# 7. An existing .zshrc is preserved as a timestamped backup.
backup=$(find "$root/home/oliver" -maxdepth 1 -name '.zshrc.bak.*' | head -n1)
[ -n "$backup" ] || fail "no backup of the pre-existing .zshrc"
[ "$(cat "$backup")" = "CUSTOM" ] || fail "backup does not hold the original content: $(cat "$backup")"
[ "$(find "$root/home/oliver" -maxdepth 1 -name '.zshrc.bak.*' | wc -l)" -eq 1 ] ||
    fail "unexpected number of .zshrc backups"
ok "a pre-existing .zshrc is kept as .zshrc.bak.<timestamp>"

# 8. Running twice is idempotent for passwd and does not clobber the payload.
before=$(cksum "$root/etc/passwd" "$root/home/oliver/.zshrc")
PATH="$ROOT_BIN:$PATH" sh "$TERMINAL" "$root" >/dev/null
[ "$before" = "$(cksum "$root/etc/passwd" "$root/home/oliver/.zshrc")" ] ||
    fail "a second run changed the passwd or the .zshrc payload"
ok "re-running the installer is idempotent"

# 9. The payload initialises Starship and stays free of CRLF line endings.
grep -q 'starship init zsh' "$ZSHRC" || fail ".zshrc does not initialise Starship"
if grep -q $'\r' "$ZSHRC"; then
    fail ".zshrc contains CRLF line endings"
fi
ok ".zshrc initialises Starship and uses LF line endings"

# 10. edit-etc-default-useradd.sh overwrites the target with SHELL=/bin/zsh.
root="$TMP/useradd"
mkdir -p "$root/etc/default"
printf 'SHELL=/bin/sh\nHOME=/home\n' >"$root/etc/default/useradd"
PATH="$ROOT_BIN:$PATH" sh "$USERADD" "$root/etc/default/useradd" >/dev/null
grep -q '^SHELL=/bin/zsh$' "$root/etc/default/useradd" || fail "SHELL=/bin/zsh missing from the target"
if grep -q '^SHELL=/bin/sh$' "$root/etc/default/useradd"; then
    fail "the old SHELL line survived the overwrite"
fi
[ "$(stat -c '%a' "$root/etc/default/useradd")" = "644" ] ||
    fail "/etc/default/useradd mode is $(stat -c '%a' "$root/etc/default/useradd"), expected 644"
ok "edit-etc-default-useradd.sh overwrites /etc/default/useradd with SHELL=/bin/zsh"

# 11. The target's parent directory is created when missing.
root="$TMP/useradd-create"
mkdir -p "$root"
PATH="$ROOT_BIN:$PATH" sh "$USERADD" "$root/etc/default/useradd" >/dev/null
grep -q '^SHELL=/bin/zsh$' "$root/etc/default/useradd" || fail "target was not created"
ok "a missing /etc/default directory is created"

# 12. A payload without SHELL=/bin/zsh is refused instead of emptying the file.
guarded="$TMP/guarded-useradd"
mkdir -p "$guarded"
cp "$USERADD" "$guarded/edit-etc-default-useradd.sh"
printf '# nothing here\n' >"$guarded/useradd"
root="$TMP/useradd-guard"
mkdir -p "$root/etc/default"
printf 'SHELL=/bin/sh\n' >"$root/etc/default/useradd"
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$guarded/edit-etc-default-useradd.sh" \
    "$root/etc/default/useradd" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "payload guard exited $rc, expected 1"
case "$out" in *'SHELL=/bin/zsh missing'*) ;; *) fail "payload guard diagnostic missing: $out" ;; esac
grep -q '^SHELL=/bin/sh$' "$root/etc/default/useradd" || fail "target was overwritten by an empty payload"
ok "a payload without SHELL=/bin/zsh is refused"

# 13. A rewrite that cannot be committed is an error, not a success message. The
#     harness skips the passwd commit step in a copy of the script, which is
#     what a non-root chroot amounts to from the script's point of view: it must
#     exit 1 and leave the old passwd intact instead of printing "Done!".
root="$TMP/not-committed"
make_root "$root"
mkdir -p "$TMP/terminal"
cp "$TERMINAL" "$TMP/terminal/edit-terminal.sh"
sabotaged="$TMP/terminal/edit-terminal.sh"
sed 's|^\(    mv -f "\$staged" "\$passwd_file"\).*|    continue|' \
    "$sabotaged" >"$sabotaged.new"
grep -q '^    continue$' "$sabotaged.new" ||
    fail "could not build the sabotaged copy of edit-terminal.sh"
mv -f "$sabotaged.new" "$sabotaged"
before=$(cksum "$root/etc/passwd")
set +e
out=$(PATH="$ROOT_BIN:$PATH" ZSHRC_SRC="$ZSHRC" sh "$sabotaged" "$root" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "an uncommitted passwd rewrite exited $rc, expected 1"
case "$out" in *'did not take effect'*) ;; *) fail "uncommitted-rewrite diagnostic missing: $out" ;; esac
[ "$before" = "$(cksum "$root/etc/passwd")" ] ||
    fail "the passwd changed even though the rewrite could not be committed"
ok "an uncommitted passwd rewrite fails instead of reporting success"

# 14. edit-etc-default-useradd.sh also refuses to report success it did not get.
# The payload copy onto the target is dropped while the rest of the script
# still runs; the read-back must catch it instead of printing a "Done!" for a
# target nothing wrote.
root="$TMP/useradd-not-committed"
mkdir -p "$root/etc/default"
printf 'SHELL=/bin/sh\n' >"$root/etc/default/useradd"
mkdir -p "$TMP/userscript"
cp "$USERADD" "$TMP/userscript/edit-etc-default-useradd.sh"
cp "$REPO_DIR/edit-etc-default-useradd/useradd" "$TMP/userscript/useradd"
sabotaged="$TMP/userscript/edit-etc-default-useradd.sh"
python3 - "$sabotaged" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
block = """cp -f useradd "$target" || {
    echo "copy fail error!" >&2
    exit 1
}"""
assert block in src, "unexpected cp block in edit-etc-default-useradd.sh"
# Neutralise only the copy: the read-back that follows must still run.
open(path, "w").write(src.replace(block, ': # sabotaged: the copy never runs'))
PYEOF
grep -q '^: # sabotaged: the copy never runs$' "$sabotaged" ||
    fail "could not build the sabotaged copy of edit-etc-default-useradd.sh"
set +e
out=$(PATH="$ROOT_BIN:$PATH" sh "$sabotaged" "$root/etc/default/useradd" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "an uncommitted useradd write exited $rc, expected 1"
case "$out" in *'did not take effect'*) ;; *) fail "useradd uncommitted-write diagnostic missing: $out" ;; esac
ok "edit-etc-default-useradd.sh fails when the target was not replaced"

printf '\nAll login-shell tests passed.\n'
