-- init.lua - modern neovim config
-- Plugin manager: lazy.nvim
-- Place at: ~/.config/nvim/init.lua
--------------------------------------------------------------------------------
-- BOOTSTRAP LAZY.NVIM
--------------------------------------------------------------------------------

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

--------------------------------------------------------------------------------
-- LEADER (must be set before lazy)
--------------------------------------------------------------------------------

vim.g.mapleader      = ","
vim.g.maplocalleader = ","

--------------------------------------------------------------------------------
-- PLUGINS
--------------------------------------------------------------------------------

require("lazy").setup({

  -- Colorscheme
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night",
      transparent = true,
      terminal_colors = true,
      styles = {
        comments = { italic = true },
        keywords = { italic = true },
        sidebars = "transparent",
        floats   = "transparent",
      },
    },
  },

  -- Status line
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      options = {
        theme                = "tokyonight",
        globalstatus         = true,
        component_separators   = { left = "", right = "" },
        section_separators = { left = "", right = "" },
      },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = { { "filename", path = 1 } },
        lualine_x = { "encoding", "fileformat", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
      tabline = {
        lualine_a = { { "buffers", show_filename_only = true, mode = 2 } },
        lualine_z = { "tabs" },
      },
    },
  },

  -- File tree
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      view = {
        width = 50,
        side  = "right",
      },
      renderer = {
        group_empty = true,
        icons = {
          show = {
            file         = true,
            folder       = true,
            folder_arrow = true,
            git          = true,
          },
        },
      },
      filters = {
        dotfiles = false,
      },
      actions = {
        open_file = {
          quit_on_open = true,
        },
      },
    },
  },

  -- Fuzzy finder
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = "Telescope",
    keys = {
      { "<leader>f", "<cmd>Telescope find_files<cr>", desc = "Find files" },
      { "<leader>b", "<cmd>Telescope buffers<cr>",    desc = "Buffers" },
      { "<leader>m", "<cmd>Telescope oldfiles<cr>",   desc = "Recent files" },
      { "<leader>/", "<cmd>Telescope live_grep<cr>",  desc = "Live grep" },
    },
  },

  -- Git integration
  {
    "tpope/vim-fugitive",
    cmd = "Git",
  },

  -- Git gutter signs
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      signs = {
        add          = { text = "▎" },
        change       = { text = "▎" },
        delete       = { text = "" },
        topdelete    = { text = "" },
        changedelete = { text = "▎" },
      },
      max_file_length = 4000,
    },
  },

  -- Commenting
  {
    "numToStr/Comment.nvim",
    opts = {},
    lazy = false,
  },

  -- Surround
  { "tpope/vim-surround" },

  -- Auto-close brackets/quotes
  { "Raimondi/delimitMate" },

  -- Undo tree
  {
    "mbbill/undotree",
    cmd = "UndotreeToggle",
  },

})

--------------------------------------------------------------------------------
-- COLORSCHEME
--------------------------------------------------------------------------------

vim.cmd("colorscheme tokyonight")

--------------------------------------------------------------------------------
-- GENERAL SETTINGS
--------------------------------------------------------------------------------

local opt = vim.opt

-- No backups or swapfiles
opt.backup      = false
opt.writebackup = false
opt.swapfile    = false

-- Persistent undo
opt.undofile   = true
opt.undodir    = vim.fn.expand("~/.local/share/nvim/undodir")
opt.undolevels = 1000
opt.undoreload = 10000

-- History
opt.history = 9999

-- Reload files changed outside nvim
opt.autoread = true

-- Allow unsaved buffers in background
opt.hidden = true

-- Faster escape sequences
opt.timeout     = true
opt.ttimeoutlen = 50
opt.timeoutlen  = 900

-- No bells
opt.errorbells = false
opt.visualbell = false

-- Backspace behaves sensibly
opt.backspace = "indent,eol,start"

--------------------------------------------------------------------------------
-- APPEARANCE
--------------------------------------------------------------------------------

opt.background    = "dark"
opt.termguicolors = true

-- Line numbers
opt.number         = true
opt.relativenumber = true
opt.numberwidth    = 6

-- Cursor line/column
opt.cursorline   = true
opt.cursorcolumn = false

-- Status line
opt.laststatus = 3
opt.showcmd    = true
opt.ruler      = true
opt.shortmess  = "atI"

-- Whitespace chars in list mode
opt.listchars = { space = "·", tab = "--", extends = "❯", precedes = "❮" }
vim.cmd([[set showbreak=↳\ ]])

-- Scrolling
opt.scrolloff     = 8
opt.sidescrolloff = 15
opt.sidescroll    = 1

-- Splits open below and to the right
opt.splitbelow = true
opt.splitright = true

-- Wildmenu
opt.wildmode = "longest,full"
opt.wildignore:append("*.o,*.obj,*.pyc,*.swp,*/.git/*,*/.hg/*,*/.svn/*")

--------------------------------------------------------------------------------
-- EDITING
--------------------------------------------------------------------------------

-- Indentation
opt.expandtab   = true
opt.tabstop     = 4
opt.shiftwidth  = 4
opt.softtabstop = 4
opt.autoindent  = true
opt.smartindent = true
opt.smarttab    = true

-- Search
opt.incsearch  = true
opt.ignorecase = true
opt.smartcase  = true

-- Virtual edit
opt.virtualedit = "all"

-- Dictionary
opt.dictionary = "/usr/share/dict/words"
opt.complete:remove("k")
opt.complete:append("k")

--------------------------------------------------------------------------------
-- FOLDING
--------------------------------------------------------------------------------

opt.foldenable = true
opt.foldmethod = "indent"
opt.foldlevel  = 100

--------------------------------------------------------------------------------
-- KEY MAPPINGS
--------------------------------------------------------------------------------

local map = vim.keymap.set

-- Edit init.lua quickly
map("n", "<leader>vv", ":e ~/.config/nvim/init.lua<CR>")

-- Cursor position toggle
vim.g.cursorposition = 0
map("n", "<C-G>h", function()
  vim.g.cursorposition = 1 - vim.g.cursorposition
  if vim.g.cursorposition == 1 then
    vim.opt.cursorline   = true
    vim.opt.cursorcolumn = true
  else
    vim.opt.cursorline   = false
    vim.opt.cursorcolumn = false
  end
end, { silent = true })

-- Y yanks to end of line
map("n", "Y", "y$")

-- Swap ' and `
map("n", "'", "`")
map("n", "`", "'")

-- Move intuitively on wrapped lines
map("n", "j", "gj")
map("n", "k", "gk")

-- Move faster
map("n", "gj", "10j")
map("n", "gk", "10k")
map("v", "gj", "10j")
map("v", "gk", "10k")

-- Goto last edit
map("n", "<leader>.", "'.zz")

-- Indent/dedent and stay in visual mode
map("n", "<", "<<")
map("n", ">", ">>")
map("v", "<", "<gv")
map("v", ">", ">gv")

-- Move lines up/down
map("n", "-k", ":m .-2<CR>==",      { silent = true })
map("n", "-j", ":m .+1<CR>==",      { silent = true })
map("v", "-j", ":m '>+1<CR>gv=gv", { silent = true })
map("v", "-k", ":m '<-2<CR>gv=gv", { silent = true })

-- Split line (opposite of J)
map("n", "S", "i<CR><Esc>^mwgk:silent! s/\\v +$//<CR>:noh<CR>`w")

-- Increment/decrement
map("n", "+",  "<C-A>")
map("n", "--", "<C-X>")

-- Clipboard
map("v", "<C-c>",      '"+y')
map("n", "<C-c>",      'gg0VG"+y')
map("n", "<C-v><C-v>", '"+p')
map("i", "<C-v><C-v>", '<Esc>"+p')

-- Leave visual mode quickly
map("v", "v", "<C-c>")

-- Search visual selection
map("v", "*", 'y/<C-R>"<CR>')

-- Consistent n/N direction
map("n", "n", "'Nn'[v:searchforward]", { expr = true })
map("n", "N", "'nN'[v:searchforward]", { expr = true })

-- Toggle switches
map("n", "<F5>",            ":set number! number?<CR>")
map("n", "<F8>",            ":set spell!<CR>")
map("n", "<F9>",            ":set hlsearch!<CR>")
map("n", "<leader><space>", ":set relativenumber!<CR>")
map("n", "<C-G>w",          ":set wrap!<CR>",  { silent = true })
map("n", "<C-G>a",          ":set list!<CR>",  { silent = true })
map("n", "<C-G>y", function()
  if vim.g.syntax_on then
    vim.cmd("syntax off")
  else
    vim.cmd("syntax enable")
  end
end, { silent = true })

-- Write with sudo
vim.cmd([[cnoremap w!! w !sudo tee % >/dev/null]])

-- Open help in vertical split
vim.cmd([[cnoreabbrev <expr> h ((getcmdtype() is# ':' && getcmdline() is# 'h') ? ('vertical help') : ('h'))]])

-- Make file executable
map("n", ",x", ":w<CR>:!chmod 755 %<CR>:e<CR>")

-- Find trailing whitespace
map("n", "<leader>fst", "/\\v\\s+$<CR>")

-- Jump lists
map("n", "<left>",  ":cprev<CR>")
map("n", "<right>", ":cnext<CR>")
map("n", "<up>",    ":lprev<CR>")
map("n", "<down>",  ":lnext<CR>")

-- Buffer navigation
map("n", "<Space><Space>", ":buffer #<CR>")
map("n", "<leader>s",      ":bn<CR>")
map("n", "<leader>a",      ":bp<CR>")
map("n", "<leader>d",      ":bd<CR>")
map("n", "<leader>D",      ":bd!<CR>")
map("n", "<leader>q",      ":qa<CR>")
map("n", "<leader>Q",      ":qa!<CR>")
map("n", "<leader>w",      ":update<CR>")

-- Buffer index shortcuts
for i = 1, 9 do
  map("n", "<leader>" .. i, ":b" .. i .. "<CR>")
end

-- Diff navigation
map("n", "dn", "]c")
map("n", "dN", "[c")

-- Plugin mappings
map("n", "<leader>tn", ":NvimTreeToggle<CR>",        { silent = true })
map("n", "<leader>ut", ":UndotreeToggle<CR>",        { silent = true })
map("n", "<C-G>g",     ":Gitsigns toggle_signs<CR>", { silent = true })

-- Fugitive
map("n", "<leader>gs", ":Git<CR>")
map("n", "<leader>gd", ":Gdiff<CR>")
map("n", "<leader>gr", ":Gread<CR>")
map("n", "<leader>gw", ":Gwrite<CR>")
map("n", "<leader>gc", ":Git commit<CR>")
map("n", "<leader>gb", ":Git blame<CR>")
map("n", "<leader>gp", ":Git pull<CR>")
map("n", "<leader>gP", ":Git push<CR>")

-- Lazy plugin management
map("n", "<leader>pi", ":Lazy install<CR>")
map("n", "<leader>pc", ":Lazy clean<CR>")
map("n", "<leader>pu", ":Lazy update<CR>")

--------------------------------------------------------------------------------
-- AUTOCOMMANDS
--------------------------------------------------------------------------------

local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

-- Auto-reload init.lua on save
augroup("reload_config", { clear = true })
autocmd("BufWritePost", {
  group   = "reload_config",
  pattern = vim.fn.expand("~/.config/nvim/init.lua"),
  command = "source <afile>",
})

-- Restore cursor position on file open
augroup("line_jump_on_open", { clear = true })
autocmd("BufReadPost", {
  group = "line_jump_on_open",
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(0) then
      vim.cmd('normal! g`"zvzz')
    end
  end,
})

-- Strip trailing whitespace on save
augroup("strip_whitespace", { clear = true })
autocmd("BufWritePre", {
  group   = "strip_whitespace",
  pattern = "*",
  command = [[%s/\s\+$//e]],
})

-- Cursor line/column: disable in insert mode and unfocused windows
augroup("cursorposition", { clear = true })
autocmd({ "WinLeave", "InsertEnter" }, {
  group    = "cursorposition",
  callback = function()
    vim.opt_local.cursorline   = false
    vim.opt_local.cursorcolumn = false
  end,
})
autocmd({ "WinEnter", "InsertLeave" }, {
  group    = "cursorposition",
  callback = function()
    if vim.g.cursorposition == 1 then
      vim.opt_local.cursorline   = true
      vim.opt_local.cursorcolumn = true
    end
  end,
})

-- Git commit settings
augroup("gitcommit", { clear = true })
autocmd("FileType", {
  group   = "gitcommit",
  pattern = "gitcommit",
  callback = function()
    vim.opt_local.number         = false
    vim.opt_local.relativenumber = false
    vim.opt_local.textwidth      = 50
    vim.opt_local.colorcolumn    = ""
  end,
})

-- vim: tw=80 sw=2 fdm=marker
vim.opt.clipboard = "unnamedplus"
