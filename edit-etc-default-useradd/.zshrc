# ~/.zshrc - Kzhento default zsh configuration
#
# Installed by Kzhento from edit-etc-default-useradd/.zshrc:
#   /etc/skel/.zshrc   every new account inherits it
#   <home>/.zshrc      existing accounts get it from edit-terminal/edit-terminal.sh
#
# It is deliberately framework-free (no oh-my-zsh) so a fresh image only needs
# the zsh and starship packages. Keep it POSIX-ish zsh and re-runnable: the
# source file is copied verbatim into every home directory.

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt append_history       # append on exit instead of rewriting the file
setopt hist_ignore_all_dups # keep one copy of every command
setopt hist_ignore_space    # a leading space keeps a command out of history
setopt hist_reduce_blanks   # squeeze extra blanks before saving
setopt share_history        # share history between running shells

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------
# dircolors supplies LS_COLORS for ls and the completion menu. It is optional:
# the rest of the file works without it.
if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors -b)"
fi

# Only initialise when compinit is available, so the file stays usable when
# zsh is installed without its function package.
if (( $+functions[compinit] )); then
    autoload -Uz compinit
    # -i skips world-writable directories instead of prompting, -u tolerates
    # files owned by another uid (possible in image-built home directories).
    compinit -i -u
fi
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}'
if [[ -n ${LS_COLORS:-} ]]; then
    zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
fi

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
alias ls='ls --color=auto --group-directories-first'
alias ll='ls -lAh'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
    alias reboot='sudo reboot'
    alias poweroff='sudo poweroff'
fi

# ---------------------------------------------------------------------------
# Prompt: Starship
# ---------------------------------------------------------------------------
# /usr/bin/starship comes from the image; the ~/.local/bin and ~/.cargo/bin
# fallbacks cover user installs. Without Starship the stock prompt is kept
# instead of printing an error on every shell start.
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init zsh)"
elif [ -x "$HOME/.local/bin/starship" ]; then
    eval "$("$HOME/.local/bin/starship" init zsh)"
elif [ -x "$HOME/.cargo/bin/starship" ]; then
    eval "$("$HOME/.cargo/bin/starship" init zsh)"
fi
