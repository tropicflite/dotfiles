# Path to your oh-my-zsh installation.
export ZSH=$HOME/.oh-my-zsh

# Theme
ZSH_THEME="agnoster"

# Plugins
plugins=(vi-mode web-search zsh-syntax-highlighting zsh-autosuggestions)

# Base PATH
export PATH=$HOME/bin:$HOME/dotfiles/packages:/usr/local/bin:$PATH
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"

# Kitty (if installed)
[ -d "$HOME/.local/kitty.app/bin" ] && export PATH="$HOME/.local/kitty.app/bin:$PATH"

source $ZSH/oh-my-zsh.sh

RPROMPT='%{$fg[cyan]%}[%D{%H:%M:%S}]%{$reset_color%}'

# Editor
export EDITOR='nvim'

# Locale
export LANG=en_CA.UTF-8

# Start SSH agent if not already running
if ! pgrep -x ssh-agent > /dev/null; then
  eval "$(ssh-agent -s)" > /dev/null
fi
ssh-add ~/.ssh/id_ed25519 2>/dev/null

# Machine name detection, computed early: the SSH_CHAIN seed block below and
# several functions further down (ssh, desktop, fdotl, fpapl) all need it.
# Canonical implementation lives in scripts/fleet/machine-name — see that
# file's header for why (used to be five separate reimplementations that had
# quietly drifted apart from each other).
_MACHINE=$(~/dotfiles/scripts/fleet/machine-name)

################################################################################
# ALIASES
################################################################################

# Navigation
alias ..="cd .."
alias cdc="cd ~/.config"
alias cdd="cd ~/dotfiles"

# Shortcuts
# Prefer batcat (Debian/Ubuntu package name) over bat if both present
if command -v batcat &>/dev/null; then
  alias bat="batcat -pp"
elif command -v bat &>/dev/null; then
  alias bat="bat -pp"
fi
alias bz="bat ~/.zshrc"
alias c="clear"
alias fd='fdfind'
alias h="history"
alias rg='rg --hidden'
alias x="exit"

# System
alias po="sudo poweroff"
alias re="sudo reboot"

# Files/directories
alias l="ls -F --color=auto --group-directories-first"
alias ll="ls -aF --color=auto --group-directories-first"
alias lll="ls -aFl --color=auto --group-directories-first"

# Package management
alias acs="apt-cache search"
alias saa="sudo apt autoremove"
alias sai="sudo apt install"
alias sar="sudo apt remove"
alias held="apt-mark showhold"

# Neovim
alias v=nvim
alias sv="sudo nvim"
alias vv="nvim ~/.config/nvim/init.lua"
alias bv="bat ~/.config/nvim/init.lua"
alias vz="nvim ~/.zshrc"
# vzl/bzl/szl operate on the per-machine local zshrc (e.g. ~/.zshrc.local.laptop).
# Defined as functions (not aliases) so $_MACHINE expands at call time, not at source time.
# unalias first in case a previous shell sourced them as aliases.
unalias vzl bzl szl 2>/dev/null
vzl() { nvim ~/.zshrc.local.$_MACHINE; }
bzl() { bat ~/.zshrc.local.$_MACHINE; }
szl() { source ~/.zshrc.local.$_MACHINE; }
alias sz="source ~/.zshrc"

# Tailscale (if installed)
if command -v tailscale &>/dev/null; then
    alias tsstatus='tailscale status &>/dev/null && echo "Tailscale: up" || echo "Tailscale: down"'
    alias tspeers='tailscale status'
fi
# ProtonVPN (if installed)
if command -v protonvpn &>/dev/null; then
    alias vpnon='protonvpn connect'
    alias vpnoff='protonvpn disconnect'
    alias vpnstatus='ip link show proton0 &>/dev/null && echo "ProtonVPN: connected" || echo "ProtonVPN: disconnected"'
fi

# Tmux
alias ta="tmux attach"
alias tk="tmux kill-session"
tn() { tmux new -s "${1:-main}"; }
alias tl="tmux ls"

# Connections (SSH aliases)
# desktop is a function (not alias) because it needs to build SSH_CHAIN before connecting.
# WSL is invoked explicitly; SSH_CHAIN is passed via -c rather than SendEnv
# because Windows sshd lands in cmd.exe, not zsh.
desktop() {
  local chain="${SSH_CHAIN:+${SSH_CHAIN}:}${_MACHINE}"
  ssh -t simin@desktop "wsl zsh -l -c 'export SSH_CHAIN=$chain; exec zsh'"
}
alias laptop='TERM=xterm-256color ssh matt@laptop'
alias mini='TERM=xterm-256color ssh matt@mini'
alias phone='ssh -p 8022 matt@phone'
alias quest='TERM=xterm-256color ssh matt@quest'
alias router='ssh admin@router'
alias server='TERM=xterm-256color ssh -p 28901 matt@server'
alias tserver='TERM=xterm-256color ssh -p 28901 matt@server -t "tmux attach || tmux new-session -s main"'
# LAN-direct fallback for when Tailscale is down on this client: tunnels Homepage's
# loopback-only port so http://localhost:3001 reaches it in a local browser.
alias homepage-backup='ssh -p 28901 -L 3001:localhost:3001 matt@192.168.50.34'

################################################################################
# KEY BINDINGS
################################################################################

bindkey -v
# KEYTIMEOUT: delay (in hundredths of a second) before accepting a key sequence.
# 20 (200ms) balances vi mode ESC responsiveness vs. accidental prefix misfires.
export KEYTIMEOUT=20
# fzf key bindings and completion
export FZF_DEFAULT_COMMAND='fdfind --hidden --follow'
[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh

################################################################################
# FUNCTIONS
################################################################################

# Recursive mkdir and cd
function mkcd {
    mkdir -p "$@" && builtin cd "$@"
}

################################################################################
# DOTFILES
################################################################################
function dotp {
  cd ~/dotfiles && git add -A && git commit -m "${1:-update dotfiles}" && git push
  cd ~/
}
function dotl {
  cd ~/dotfiles || { echo "⚠ dotl: ~/dotfiles not found"; return 1; }
  # Force a clean re-fetch: delete packed-refs and the origin/master ref (git
  # rebuilds both below) plus any leftover index.lock from an interrupted op.
  # This clears the diverged/corrupted refs that the cross-machine hard-reset
  # workflow can produce. NOTE: the reset --hard below discards ALL uncommitted
  # changes in ~/dotfiles, so nothing machine-local should be tracked here.
  rm -f .git/packed-refs
  rm -f .git/refs/remotes/origin/master
  rm -f .git/index.lock
  git fetch --prune --force origin && git reset --hard origin/master || { echo "⚠ dotl: sync failed — check ~/dotfiles"; cd ~/; return 1; }
  cd ~/
}
# Fleet-wide dotfiles pull — runs dotl on all machines via SSH.
fdotl() {
  local me=$_MACHINE
  # Helper defined inline so it doesn't pollute the global function namespace;
  # unfunction cleans it up when fdotl returns.
  _fdotl_check() {
    local host=$1 exit=$2
    if [[ $exit -eq 255 ]]; then
      echo "⚠️  $host: offline or unreachable (skipped)"
    elif [[ $exit -ne 0 ]]; then
      echo "⚠️  $host: dotl failed (exit $exit)"
    fi
  }
  for host in mini server laptop desktop phone quest; do
    if [[ "$host" == "$me" ]]; then
      echo "==> $host (self, running locally)"
      ~/dotfiles/scripts/fleet/dotl
    elif [[ "$host" == "desktop" ]]; then
      echo "==> $host"
      # desktop requires WSL invocation; standard ssh would land in cmd.exe
      ssh -q -o ConnectTimeout=10 simin@$host "wsl zsh ~/dotfiles/scripts/fleet/dotl"
      _fdotl_check $host $?
    else
      echo "==> $host"
      ssh -q -o ConnectTimeout=10 matt@$host "zsh ~/dotfiles/scripts/fleet/dotl"
      _fdotl_check $host $?
    fi
  done
  unfunction _fdotl_check
}
fpapl() {
  local me=$_MACHINE
  _fpapl_check() {
    local host=$1 exit=$2
    if [[ $exit -eq 255 ]]; then
      echo "⚠️  $host: offline or unreachable (skipped)"
    elif [[ $exit -ne 0 ]]; then
      echo "⚠️  $host: packages-pull failed (exit $exit)"
    fi
  }
  for host in mini server laptop desktop phone quest; do
    if [[ "$host" == "$me" ]]; then
      echo "==> $host (self, running locally)"
      zsh -i -c packages-pull
    elif [[ "$host" == "desktop" ]]; then
      echo "==> $host"
      ssh -q -o ConnectTimeout=10 simin@$host "wsl zsh -i -c packages-pull"
      _fpapl_check $host $?
    else
      echo "==> $host"
      ssh -q -o ConnectTimeout=10 matt@$host "zsh -i -c packages-pull"
      _fpapl_check $host $?
    fi
  done
  unfunction _fpapl_check
}
# ── SSH hop chain ─────────────────────────────────────────────
# Tracks the full path of SSH hops in the prompt (e.g. laptop ❯ server ❯ mini).
# SSH_CHAIN is a colon-separated list of hostnames, rendered with ❯ separators.

# Seed: when we arrive on this machine via SSH and no chain exists yet, start one.
if [[ -n $SSH_CONNECTION && -z $SSH_CHAIN ]]; then
  export SSH_CHAIN=$_MACHINE
fi

# Wrapper: intercepts all outgoing ssh calls to append this machine to the chain
# before passing it to the next hop via SendEnv.
ssh() {
  local chain="${SSH_CHAIN:+${SSH_CHAIN}:}${_MACHINE}"
  env SSH_CHAIN="$chain" /usr/bin/ssh -o SendEnv=SSH_CHAIN "$@"
}

# Prompt segment: renders the chain in the Agnoster prompt (left side, before status).
prompt_ssh_chain() {
  [[ -z $SSH_CHAIN ]] && return
  prompt_segment cyan black " ${SSH_CHAIN//:/ ❯ } "
}
# Agnoster's build_prompt is overridden here to inject prompt_ssh_chain first.
build_prompt() {
  RETVAL=$?
  prompt_ssh_chain
  prompt_status
  prompt_virtualenv
  prompt_aws
  prompt_terraform
  prompt_context
  prompt_dir
  prompt_git
  prompt_bzr
  prompt_hg
  prompt_end
}

# Per-machine zshrc loading. _MACHINE was already computed near the top of
# this file (before it's needed by the SSH_CHAIN seed block and others).
[ -f ~/.zshrc.local.$_MACHINE ] && source ~/.zshrc.local.$_MACHINE

# Full system update: update, upgrade, autoremove, then report any held packages.
sauu() {
  sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y
  local held=$(apt-mark showhold)
  [[ -n "$held" ]] && echo "\n⚠ Held packages:\n$held"
}
