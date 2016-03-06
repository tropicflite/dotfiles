tropicflite's Configuration Files
===========================

These are some configuration files ("dotfiles", "rc files", ...).

I use git to version control and github to sync them. Feel free to have a look!


## Usage

First clone this project via

    git clone https://github.com/tropicflite/dotfiles

    Then change into the cloned directory (this is important for the script to work!)

        cd ./dotfiles

        Finally, install my configuration with the installation script

            ./install.sh [OPTIONS] TARGET

            where `TARGET` can either be an item from the targets listed below, or `all` to install every target.

### Example

    ./install.sh -i vim


## Targets

* `bash` basic stuff for bash, will be sourced additionally
* `git` global git configuration
* `i3` tiling window manager
* `mutt` a really nerdy mail client for the terminal
* `ranger` file manager for the terminal
* `tmux` a must have for terminal junkies
* `vim` the best reason not to use emacs
* `vimperator` vim-addon for firefox
* `zathura` pdf viewer

## Contact

If you have got any questions or comments, please just shoot me a mail: siminstructor@gmail.com
