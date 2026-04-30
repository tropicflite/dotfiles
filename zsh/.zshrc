# Path to your oh-my-zsh installation.
export ZSH=$HOME/.oh-my-zsh

# Theme
ZSH_THEME="agnoster"
DEFAULT_USER=matt

# Plugins
plugins=(vi-mode web-search zsh-syntax-highlighting zsh-autosuggestions)

# Base PATH
export PATH=$HOME/bin:$HOME/dotfiles/packages:/usr/local/bin:$PATH
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"

# Kitty (if installed)
[ -d "$HOME/.local/kitty.app/bin" ] && export PATH="$HOME/.local/kitty.app/bin:$PATH"

source $ZSH/oh-my-zsh.sh

# Editor
export EDITOR='nvim'

# Locale
export LANG=en_CA.UTF-8

# Start SSH agent if not already running
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
  eval "$(ssh-agent -s)" > /dev/null
fi
ssh-add ~/.ssh/id_ed25519 2>/dev/null

################################################################################
# ALIASES
################################################################################

# Navigation
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
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
alias q="exit"
alias x="exit"
alias ':q!'='exit 1'    # "force quit without saving" - exit with error code
alias :wq="exit"
alias u="uname -a"
alias s="sudo "
alias sudo="sudo "

# System
alias po="sudo poweroff"
alias re="sudo reboot"

# Files/directories
alias l="ls -F --color=auto --group-directories-first"
alias ll="ls -aF --color=auto --group-directories-first"
alias lll="ls -aFl --color=auto --group-directories-first"
alias sl="find . -type l -ls"
alias df='df -h'

# Package management
alias acs="apt-cache search"
alias saa="sudo apt autoremove"
alias sai="sudo apt install"
alias sar="sudo apt remove"
alias sauu="sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y"

# Neovim
alias v=nvim
alias vim=nvim
alias sv="sudo nvim"
alias vv="nvim ~/.config/nvim/init.lua"
alias bv="bat ~/.config/nvim/init.lua"
alias vz="nvim ~/.zshrc"
alias bz="bat ~/.zshrc"
# local zshrc helpers (functions to allow $_MACHINE expansion at runtime)
vzl() { nvim ~/.zshrc.local.$_MACHINE; }
bzl() { bat ~/.zshrc.local.$_MACHINE; }
szl() { source ~/.zshrc.local.$_MACHINE; }
alias sz="source ~/.zshrc"

# Network
alias myip='curl -s -4 ifconfig.me && echo'
alias ports='ss -tulanp'

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
_MACHINE=$([ -n "$PREFIX" ] && echo phone || echo "${HOST%%.*}")
[ -f ~/.zshrc.local.$_MACHINE ] && source ~/.zshrc.local.$_MACHINE
