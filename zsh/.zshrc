# Path to your oh-my-zsh installation.
export ZSH=$HOME/.oh-my-zsh

# Theme
ZSH_THEME="clean"

# Plugins
plugins=(vi-mode web-search zsh-syntax-highlighting zsh-autosuggestions)

# Base PATH
export PATH=$HOME/bin:$HOME/dotfiles/packages:/usr/local/bin:$PATH

# Kitty (if installed)
[ -d "$HOME/.local/kitty.app/bin" ] && export PATH="$HOME/.local/kitty.app/bin:$PATH"

source $ZSH/oh-my-zsh.sh

# Editor
export EDITOR='nvim'

# Locale
export LANG=en_CA.UTF-8

################################################################################
# ALIASES
################################################################################

# Navigation
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias cdd="cd ~/dotfiles"

# Shortcuts
command -v batcat &>/dev/null && alias bat="batcat -pp" || command -v bat &>/dev/null && alias bat="bat -pp"
alias c="clear"
alias cdc="cd && clear"
alias h="history"
alias q="exit"
alias x="exit"
alias :wq="exit"
alias u="uname -a"
alias s="sudo "
alias sudo="sudo "

# System
alias po="sudo poweroff"
alias re="sudo reboot"

# Files/directories
alias l="ls --color=auto --group-directories-first"
alias ll="ls -aF --color=auto --group-directories-first"
alias lll="ls -aFl --color=auto --group-directories-first"
alias sl="find . -type l -ls"
alias rm="rm"
alias df='df -h'
alias du='du -h --max-depth=1'

# Package management
alias acs="apt-cache search"
alias saa="sudo apt autoremove"
alias sai="sudo apt install"
alias sar="sudo apt remove"
alias sauu="sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y"

# Neovim
alias v=nvim
alias v3="nvim ~/.config/i3/config"
alias b3="bat ~/.config/i3/config"
alias vk="nvim ~/.config/kitty/kitty.conf"
alias bk="bat ~/.config/kitty/kitty.conf"
alias vim=nvim
alias sv="sudo nvim"
alias vv="nvim ~/.config/nvim/init.lua"
alias bv="bat ~/.config/nvim/init.lua"
alias vz="nvim ~/.zshrc"
alias bz="bat ~/.zshrc"
# local zshrc helpers (functions to allow $_MACHINE expansion at runtime)
vzl() { nvim ~/.zshrc.local.$_MACHINE; }
bzl() { bat ~/.zshrc.local.$_MACHINE; }
alias sz="source ~/.zshrc"

# Network
alias myip='curl -s -4 ifconfig.me && echo'
alias ports='ss -tulanp'

# Ranger connect and disconnect
alias rpcon='mkdir -p ~/mnt/phone && fusermount -u ~/mnt/phone 2>/dev/null; sshfs -p 8022 u0_a243@phone: ~/mnt/phone && ranger ~/mnt/phone'
alias rpdis='fusermount -u ~/mnt/phone'

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

# Connections (SSH aliases)
alias desktop='ssh simin@desktop'
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

# Extract archives
extract() {
    local c e i

    (($#)) || return

    for i; do
        c=''
        e=1

        if [[ ! -r $i ]]; then
            echo "$0: file is unreadable: \`$i'" >&2
            continue
        fi

        case $i in
            *.t@(gz|lz|xz|b@(2|z?(2))|a@(z|r?(.@(Z|bz?(2)|gz|lzma|xz)))))
                   c='bsdtar xvf';;
            *.7z)  c='7z x';;
            *.Z)   c='uncompress';;
            *.bz2) c='bunzip2';;
            *.exe) c='cabextract';;
            *.gz)  c='gunzip';;
            *.rar) c='unrar x';;
            *.xz)  c='unxz';;
            *.zip) c='unzip';;
            *)     echo "$0: unrecognized file extension: \`$i'" >&2
                   continue;;
        esac

        command $c "$i"
        e=$?
    done

    return $e
}

################################################################################
# DOTFILES
################################################################################
function dotp {
  cd ~/dotfiles && git add -A && git commit -m "${1:-update dotfiles}"; git push
  cd ~/
}
function dotl {
  cd ~/dotfiles && git fetch --prune --force origin && git pull || echo "⚠ dotl: pull failed — check ~/dotfiles for conflicts"
  cd ~/
}
# Fleet-wide dotfiles pull
fdotl() {
  local me=$(hostname)
  for host in mini server laptop desktop; do
    if [[ "$host" == "$me" ]]; then
      echo "==> $host (self, running locally)"
      zsh -i -c dotl
    elif [[ "$host" == "server" ]]; then
      echo "==> $host"
      ssh -p 28901 matt@$host "zsh -i -c dotl" || echo "⚠️  $host failed or unreachable"
    elif [[ "$host" == "desktop" ]]; then
      echo "==> $host"
      ssh -q simin@$host "wsl zsh -i -c dotl" || echo "⚠️  $host failed or unreachable"
    else
      echo "==> $host"
      ssh matt@$host "zsh -i -c dotl" || echo "⚠️  $host failed or unreachable"
    fi
  done
  echo "==> phone: run dotl manually"
}

# Git pull on login
(dotl > /dev/null 2>&1 &)
_MACHINE=$([ -n "$PREFIX" ] && echo phone || echo "${HOST%%.*}")
[ -f ~/.zshrc.local.$_MACHINE ] && source ~/.zshrc.local.$_MACHINE
