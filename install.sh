#!/bin/bash

function print_help_msg() {
    cat <<-EOF
Create symbolic links to these files where applications want them.

Usage: install.sh [OPTIONS] TARGET

    OPTIONS:
    -h | --help             print this help message
    -i | --interactive      if file(s) exist(s), ask what to do
    -f | --force            if file(s) exist(s), overwrite it/them

    TARGET := { all | bash | git | i3 | mutt | ranger
                tmux | vim | vimperator | zathura }
EOF
}


function create_link_for_target() {
    local TARGET="$1"
    case "$TARGET" in

        git)
            create_link $PWD/git/gitconfig $HOME/.gitconfig
            create_link $PWD/git/gitignore $HOME/.gitignore
            ;;

        i3)
            mkdir -p $HOME/.i3
            create_link $PWD/i3/config $HOME/.i3/config
            create_link $PWD/i3/background.jpg $HOME/.i3/background.jpg
            ;;

        mutt)
            create_link $PWD/mutt/muttrc $HOME/.muttrc
            ;;

        ranger)
            mkdir -p $HOME/.config/ranger
            create_link $PWD/ranger/rc.conf $HOME/.config/ranger/rc.conf
            create_link $PWD/ranger/rifle.conf $HOME/.config/ranger/rifle.conf
            create_link $PWD/ranger/scope.sh $HOME/.config/ranger/scope.sh
            chmod u+x $HOME/.config/ranger/scope.sh
            create_link $PWD/ranger/colorschemes $HOME/.config/ranger/colorschemes
            ;;

        tmux)
            create_link $PWD/tmux/tmux.conf $HOME/.tmux.conf
            ;;

        vim)
            create_link $PWD/vim/vimrc $HOME/.vimrc
            mkdir -p $HOME/.vim
            mkdir -p $HOME/.vim/undodir
            ;;

        vimperator)
            create_link $PWD/vimperator/vimperatorrc $HOME/.vimperatorrc
            ;;

        zathura)
            mkdir -p $HOME/.config/zathura
            create_link $PWD/zathura/zathurarc $HOME/.config/zathura/zathurarc
            ;;

        *)
            echo "Unknown target: $1"
            echo "Type './install --help' for a list of valid targets."
            ;;
    esac
}


function create_link() {
    local DESTPATH="$1"
    local LINKPATH="$2"

    if [[ $FORCE = true ]]; then
        ln -nsf $DESTPATH $LINKPATH

    elif [[ $INTERACTIVE = true ]]; then
        ln -nsi $DESTPATH $LINKPATH

    else
        ln -ns $DESTPATH $LINKPATH

    fi
}



# check if script is executed in this very dotfiles directory
# (otherwise the creating of links won't work!)
if [[ $0 != "./install.sh" ]]; then
    echo "Please change into the directory containing this script to execute it!"
    exit 1
fi


# get arguments
INTERACTIVE=false
FORCE=false
TEMP=`getopt -o hif --long help,interactive,force -n 'test.sh' -- "$@"`
eval set -- "$TEMP"
while true ; do
    case "$1" in
        -h|--help) print_help_msg; exit 0 ;;
        -i|--interactive) INTERACTIVE=true; shift ;;
        -f|--force) FORCE=true ; shift ;;
        --) shift ; break ;;
        *) echo "Internal error!" ; exit 1 ;;
    esac
done


# test options
# note that both are not allowed simultaneously!
if [ $INTERACTIVE = true ] && [ $FORCE = true ]; then
    echo "You can not use interactive and force mode together!"
    # print_help_msg
    exit 1
fi


# we currently only handle one target
if [[ $# -eq 0 ]]; then
    print_help_msg
    exit 0
elif [[ $# -gt 1 ]]; then
    echo "Please specify exactly one target! It can be 'all'."
    exit 1
else
    if [[ $1 = dactyl ]]; then
        create_link_for_target pentadactyl
    elif [[ $1 = all ]]; then
        create_link_for_target git
        create_link_for_target i3
        create_link_for_target mutt
        create_link_for_target ranger
        create_link_for_target tmux
        create_link_for_target vim
        create_link_for_target vimperator
        create_link_for_target zathura
    else
        create_link_for_target $1
    fi
    exit 0
fi




