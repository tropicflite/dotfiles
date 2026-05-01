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

################################################################################
# ALIASES
################################################################################

# Navigation
alias ..="cd .."
alias cdc="cd ~/.config"
alias cdd="cd ~/dotfiles"

# Shortcuts
if command -v batcat &>/dev/null; then
  alias bat="batcat -pp"
elif command -v bat &>/dev/null; then
  alias bat="bat -pp"
fi
alias c="clear"
alias h="history"
alias x="exit"
alias s="sudo "
alias sudo="sudo "

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
alias sauu="sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y"

# Neovim
alias v=nvim
alias sv="sudo nvim"
alias vv="nvim ~/.config/nvim/init.lua"
alias bv="bat ~/.config/nvim/init.lua"
alias vz="nvim ~/.zshrc"
alias bz="bat ~/.zshrc"
# local zshrc helpers (functions to allow $_MACHINE expansion at runtime)
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
alias tn="tmux new -s"
alias tl="tmux ls"

# Connections (SSH aliases)
alias desktop='ssh -t simin@desktop "wsl zsh -l"'
alias laptop='TERM=xterm-256color ssh matt@laptop'
alias phone='ssh -p 8022 matt@phone'
alias server='TERM=xterm-256color ssh -p 28901 matt@server'
alias mini='TERM=xterm-256color ssh matt@mini'

################################################################################
# KEY BINDINGS
################################################################################

bindkey -v
export KEYTIMEOUT=20
bindkey "^R" history-incremental-pattern-search-backward

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
  rm -f .git/packed-refs
  rm -f .git/refs/remotes/origin/master
  rm -f .git/index.lock
  git fetch --prune --force origin && git reset --hard origin/master || { echo "⚠ dotl: sync failed — check ~/dotfiles"; cd ~/; return 1; }
  cd ~/
}
# Fleet-wide dotfiles pull
fdotl() {
  local me=${HOST%%.*}
  _fdotl_check() {
    local host=$1 exit=$2
    if [[ $exit -eq 255 ]]; then
      echo "⚠️  $host: SSH connection failed"
    elif [[ $exit -ne 0 ]]; then
      echo "⚠️  $host: dotl failed (exit $exit)"
    fi
  }
  for host in mini server laptop desktop phone; do
    if [[ "$host" == "$me" ]]; then
      echo "==> $host (self, running locally)"
      zsh -i -c dotl
    elif [[ "$host" == "desktop" ]]; then
      echo "==> $host"
      ssh -q simin@$host "wsl zsh -i -c dotl"
      _fdotl_check $host $?
    else
      echo "==> $host"
      ssh -q matt@$host "zsh -i -c dotl"
      _fdotl_check $host $?
    fi
  done
  unfunction _fdotl_check
}
# Git pull on login
[[ -o login ]] && (dotl > /dev/null 2>&1 &)
# ── SSH hop chain ─────────────────────────────────────────────
# Seed chain when we arrive via SSH
if [[ -n $SSH_CONNECTION && -z $SSH_CHAIN ]]; then
  export SSH_CHAIN=$(echo $SSH_CONNECTION | awk '{print $1}')
fi

# Extend chain when we SSH outward
ssh() {
  local chain="${SSH_CHAIN:+${SSH_CHAIN} ❯ }$(hostname -s)"
  env SSH_CHAIN="$chain" /usr/bin/ssh -o SendEnv=SSH_CHAIN "$@"
}

# Add SSH chain segment and redefine build_prompt to include it
prompt_ssh_chain() {
  [[ -z $SSH_CHAIN ]] && return
  prompt_segment cyan black " $SSH_CHAIN "
}

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
_MACHINE=$([ -n "$PREFIX" ] && echo phone || echo "${HOST%%.*}")
[ -f ~/.zshrc.local.$_MACHINE ] && source ~/.zshrc.local.$_MACHINE
