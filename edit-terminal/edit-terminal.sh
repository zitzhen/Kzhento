#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only
#
# Switch every existing account to /bin/zsh and install the Kzhento .zshrc with
# the Starship prompt:
#
#   /etc/passwd        login shell of root and of every regular account
#                      (uid >= 1000) becomes /bin/zsh; system accounts,
#                      nobody (65534) and accounts on nologin/false shells
#                      are left alone
#   /etc/skel/.zshrc   template for accounts created later
#   <home>/.zshrc      for the accounts above; an existing file is kept as
#                      .zshrc.bak.<timestamp> so user customisations survive
#
# Accounts created after the image is built are covered by
# edit-etc-default-useradd/edit-etc-default-useradd.sh.
#
# Usage:
#   sudo ./edit-terminal.sh                  # this system, or inside chroot
#   sudo ./edit-terminal.sh <target root>    # e.g. an unpacked root directory;
#                                            # writes <root>/etc/passwd,
#                                            # <root>/etc/skel/.zshrc and
#                                            # <root>/home/*/.zshrc
#
# Environment:
#   ZSHRC_SRC   .zshrc payload (default: ../edit-etc-default-useradd/.zshrc)

set -e

# switch to script dir, so default relative paths always work
cd "$(dirname "$0")" || exit 1

# check users
if [ "$(id -u)" -ne 0 ]; then
    echo "No root! exit!" >&2
    exit 1
fi

# Target: prefer the argument, otherwise edit the running system / chroot.
# "/" and "" both mean the running root; a trailing slash is dropped so
# "$root/etc/passwd" never ends up as "//etc/passwd".
root=${1:-}
case "$root" in
'') root='' ;;
/) root='' ;;
*/) root=${root%/} ;;
esac

passwd_file="$root/etc/passwd"
if [ ! -f "$passwd_file" ]; then
    echo "passwd not found: $passwd_file" >&2
    exit 1
fi

# The zsh package is installed by install-app/zsh.sh; without it the login
# shell would point at a binary that does not exist. Check the target tree when
# one is given, otherwise the running system (which is also the chroot root).
zsh_ok=0
for zsh in "$root/bin/zsh" "$root/usr/bin/zsh"; do
    if [ -x "$zsh" ]; then
        zsh_ok=1
        break
    fi
done
if [ "$zsh_ok" -ne 1 ]; then
    echo "zsh is not installed (no /bin/zsh), exiting" >&2
    exit 1
fi

zshrc_src=${ZSHRC_SRC:-"$PWD/../edit-etc-default-useradd/.zshrc"}
if [ ! -f "$zshrc_src" ]; then
    zshrc_src=$PWD/.zshrc
fi
if [ ! -f "$zshrc_src" ]; then
    echo ".zshrc not found (looked in ../edit-etc-default-useradd/ and $PWD), exiting" >&2
    exit 1
fi

# One pass over passwd rewrites the shell column and records "uid:gid:home"
# for the accounts that were changed, so the .zshrc copies use the right owner.
#
# accounts() lists the logins that are switched: root and regular accounts
# (uid >= 1000) whose shell is a real one. System accounts, nobody (65534) and
# anything on nologin/false/sync/halt/shutdown are left alone.
# shellmap() turns that output into the "uid:gid:home" lines used below. Both
# are fed from the same file, so the write-back check re-derives the account
# list instead of trusting what the rewrite did.
accounts() {
    awk -F: '
        BEGIN { n = split("nologin false sync halt shutdown", bad, " ") }
        {
            # name:passwd:uid:gid:gecos:home:shell - skip anything unexpected,
            # including duplicate uid 0 accounts: only the real root ($1=="root")
            # is switched, so a shadowing alias never becomes zsh.
            if (NF != 7 || $3 !~ /^[0-9]+$/ || $6 !~ /^\//) next
            skip = 0
            for (i = 1; i <= n; i++) {
                if (index($7, bad[i]) > 0) skip = 1
            }
            if (skip) next
            if ($3 + 0 == 0) { if ($1 == "root") print; next }
            if ($3 + 0 >= 1000) print
        }
    ' "$1"
}
shellmap() {
    awk -F: '{ print $3 ":" $4 ":" $6 }'
}

tmp="$passwd_file.zhento.$$"
homes="$passwd_file.homes.$$"
want="$passwd_file.want.$$"
trap 'rm -f "$tmp" "$homes" "$want"' EXIT HUP INT TERM
accounts "$passwd_file" >"$want" || {
    echo "list accounts fail error!" >&2
    exit 1
}
if [ ! -s "$want" ]; then
    echo "no account to switch in $passwd_file, exiting" >&2
    exit 1
fi

awk -F: -v OFS=: -v list="$want" '
    BEGIN { while ((getline line < list) > 0) { split(line, f, ":"); switch_[f[1]] = 1 } }
    ($1 in switch_) { $7 = "/bin/zsh" }
    { print }
' "$passwd_file" >"$tmp" || {
    echo "rewrite fail error!" >&2
    exit 1
}
shellmap <"$want" >"$homes" || {
    echo "write $homes fail error!" >&2
    exit 1
}

# Template first: new accounts pick it up through SKEL=/etc/skel.
skel_dir="$root/etc/skel"
mkdir -p "$skel_dir" || {
    echo "mkdir fail error!" >&2
    exit 1
}
cp -f "$zshrc_src" "$skel_dir/.zshrc" || {
    echo "copy .zshrc to $skel_dir fail error!" >&2
    exit 1
}
chmod 0644 "$skel_dir/.zshrc" || {
    echo "chmod fail error!" >&2
    exit 1
}

# Existing home directories get their own copy, with a timestamped backup of
# any file the user (or a previous image build) already has.
stamp=$(date +%Y%m%d%H%M%S)
count=0
while IFS=: read -r uid gid home || [ -n "$uid" ]; do
    if [ -z "$home" ] || [ "$home" = "/" ] || [ ! -d "$root$home" ]; then
        continue
    fi
    if [ "$home" = "/etc/skel" ]; then
        continue
    fi
    dir="$root$home"
    if [ -f "$dir/.zshrc" ]; then
        cp -f "$dir/.zshrc" "$dir/.zshrc.bak.$stamp" || {
            echo "backup $dir/.zshrc fail error!" >&2
            exit 1
        }
        chown "$uid:$gid" "$dir/.zshrc.bak.$stamp" 2>/dev/null || true
        chmod 0644 "$dir/.zshrc.bak.$stamp" || {
            echo "chmod $dir/.zshrc.bak.$stamp fail error!" >&2
            exit 1
        }
    fi
    cp -f "$zshrc_src" "$dir/.zshrc" || {
        echo "copy .zshrc to $dir fail error!" >&2
        exit 1
    }
    chown "$uid:$gid" "$dir/.zshrc" 2>/dev/null || true
    chmod 0644 "$dir/.zshrc" || {
        echo "chmod $dir/.zshrc fail error!" >&2
        exit 1
    }
    count=$((count + 1))
done <"$homes"

# Swap the rewritten passwd in last, so a failure above never leaves the
# system with a half-updated shell table. A non-root caller (a chroot that was
# not entered as uid 0, for example) cannot replace /etc/passwd at all, so
# write to a scratch file in the same directory and rename it into place: the
# rename either happened or not, and the read-back below proves which.
staged="$passwd_file.zhento.new.$$"
trap 'rm -f "$tmp" "$homes" "$want" "$staged"' EXIT HUP INT TERM
chmod 0644 "$tmp" || {
    echo "chmod fail error!" >&2
    exit 1
}
base_inode=$(ls -i "$passwd_file" 2>/dev/null | awk '{print $1}')
# Two attempts: a transient write failure retries once; a permission problem
# fails both times and is then reported by the read-back below.
for _ in 1 2; do
    cp -f "$tmp" "$staged" 2>/dev/null || continue
    mv -f "$staged" "$passwd_file" 2>/dev/null || continue
    now_inode=$(ls -i "$passwd_file" 2>/dev/null | awk '{print $1}')
    [ "$now_inode" != "$base_inode" ] || continue
    if awk -F: -v list="$want" '
        BEGIN { while ((getline line < list) > 0) { split(line, f, ":"); switch_[f[1]] = 1 } }
        NF != 7 || !($1 in switch_) || $7 == "/bin/zsh" { next }
        { bad = 1 }
        END { exit bad }
    ' "$passwd_file" 2>/dev/null; then
        break
    fi
done
rm -f "$staged"
if ! awk -F: -v list="$want" '
    BEGIN { while ((getline line < list) > 0) { split(line, f, ":"); switch_[f[1]] = 1 } }
    NF == 7 && ($1 in switch_) && $7 != "/bin/zsh" { bad = bad " " $1 }
    END { if (bad != "") { print "not on zsh:" bad; exit 1 } }
' "$passwd_file"; then
    echo "replace $passwd_file did not take effect, exiting" >&2
    exit 1
fi

echo "Done! Edit login shells OK! -> $passwd_file"
echo "Done! Install .zshrc OK! -> $skel_dir/.zshrc and $count home directory(ies)"
