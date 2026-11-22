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
#                      (uid >= 1000) becomes /bin/zsh; system accounts and
#                      accounts on nologin/false shells are left alone
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
tmp="$passwd_file.zhento.$$"
homes="$passwd_file.homes.$$"
trap 'rm -f "$tmp" "$homes"' EXIT HUP INT TERM
: >"$homes" || {
    echo "write $homes fail error!" >&2
    exit 1
}

awk -F: -v OFS=: -v homes="$homes" '
    BEGIN { n = split("nologin false sync halt shutdown", bad, " ") }
    {
        # name:passwd:uid:gid:gecos:home:shell - keep anything unexpected as-is.
        if (NF == 7 && $3 ~ /^[0-9]+$/ && $6 ~ /^\//) {
            skip = 0
            for (i = 1; i <= n; i++) {
                if (index($7, bad[i]) > 0) skip = 1
            }
            if (!skip && ($3 + 0 == 0 || $3 + 0 >= 1000)) {
                $7 = "/bin/zsh"
                print $3 ":" $4 ":" $6 > homes
            }
        }
        print
    }
' "$passwd_file" >"$tmp" || {
    echo "rewrite fail error!" >&2
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
    dir="$root$home"
    if [ "$dir" = "$skel_dir" ]; then
        continue
    fi
    if [ -f "$dir/.zshrc" ]; then
        cp -f "$dir/.zshrc" "$dir/.zshrc.bak.$stamp" || {
            echo "backup $dir/.zshrc fail error!" >&2
            exit 1
        }
        chown "$uid:$gid" "$dir/.zshrc.bak.$stamp" 2>/dev/null || true
        chmod 0644 "$dir/.zshrc.bak.$stamp" || true
    fi
    cp -f "$zshrc_src" "$dir/.zshrc" || {
        echo "copy .zshrc to $dir fail error!" >&2
        exit 1
    }
    chown "$uid:$gid" "$dir/.zshrc" 2>/dev/null || true
    chmod 0644 "$dir/.zshrc" || true
    count=$((count + 1))
done <"$homes"

# Swap the rewritten passwd in last, so a failure above never leaves the
# system with a half-updated shell table.
chmod 0644 "$tmp" || {
    echo "chmod fail error!" >&2
    exit 1
}
mv -f "$tmp" "$passwd_file" || {
    echo "replace $passwd_file fail error!" >&2
    exit 1
}

echo "Done! Edit login shells OK! -> $passwd_file"
echo "Done! Install .zshrc OK! -> $skel_dir/.zshrc and $count home directory(ies)"
