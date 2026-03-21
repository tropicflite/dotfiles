# Path to your oh-my-zsh installation.
export ZSH=$HOME/.oh-my-zsh

# Theme
ZSH_THEME="clean"

# Plugins
plugins=(vi-mode web-search zsh-syntax-highlighting zsh-autosuggestions)

export PATH=$HOME/bin:/usr/local/bin:$PATH

source $ZSH/oh-my-zsh.sh

# Editor
export EDITOR='nvim'

################################################################################
# ALIASES
################################################################################

# Navigation
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."

# Shortcuts
alias c="clear"
alias cdc="cd && clear"
alias h="history"
alias q="exit"
alias :q="exit"
alias wq="exit"
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
alias scp="rsync --rsh=ssh --archive --append --human-readable --progress --times"
alias rm="rm"
alias df='df -h'
alias du='du -h --max-depth=1'

# Package management
alias acs="apt-cache search"
alias saa="sudo apt autoremove"
alias sai="sudo apt install"
alias sar="sudo apt remove"
alias sauu="sudo apt update && sudo apt upgrade"

# Neovim
alias v=nvim
alias vim=nvim
alias sv="sudo nvim"
alias vv="nvim ~/.config/nvim/init.lua"
alias vz="nvim ~/.zshrc"
alias sz="source ~/.zshrc"

# ProtonVPN
alias vpnon='protonvpn connect'
alias vpnoff='protonvpn disconnect'
alias vpnstatus='ip link show proton0 &>/dev/null && echo "ProtonVPN: connected" || echo "ProtonVPN: disconnected"'

# Tailscale
alias tson='sudo service tailscaled start && sudo tailscale up'
alias tsoff='sudo tailscale down && sudo service tailscaled stop'
alias tsstatus='tailscale status &>/dev/null && echo "Tailscale: up" || echo "Tailscale: down"'

# Trackpad on/off
alias tpon='xinput enable 15 && echo "Touchpad enabled"'
alias tpoff='xinput disable 15 && echo "Touchpad disabled"'

# Network
alias netstatus='vpnstatus && tsstatus'
alias myip='curl -s -4 ifconfig.me && echo'
alias ports='ss -tulanp'

# Remote
alias server='TERM=xterm-256color ssh -p 28901 matt@100.83.216.18'
alias fb='xdg-open https://debian.tailc9871d.ts.net'

################################################################################
# KEY BINDINGS
################################################################################

bindkey -v
export KEYTIMEOUT=20
bindkey "^R" history-incremental-pattern-search-backward

################################################################################
# FUNCTIONS
################################################################################

# Auto ls after cd
function cd {
    builtin cd "$@" && ll
}

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

export PATH="$HOME/.local/kitty.app/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"
