vim.opt.syntax = "on"
vim.opt.number = true
-- vim.opt.numberwidth = 2 -- Width of the line number column
vim.opt.formatoptions:remove({ "o" })

vim.opt.tabstop = 3 -- Number of spaces for a tab
vim.opt.expandtab = true -- Use spaces instead of tabs
vim.opt.softtabstop = 3 -- Number of spaces for a tab when editing
vim.opt.shiftwidth = 3 -- Number of spaces for autoindent
vim.opt.shiftround = true -- Round indent to multiple of shiftwidth

vim.opt.linebreak = true
vim.opt.list = true -- Show whitespace characters
vim.opt.listchars = "tab: ,multispace:|   " -- Characters to show for tabs, spaces, and end of line
vim.opt.wrap = true -- line wrapping
vim.opt.cursorline = true -- Highlight the current line
vim.opt.scrolloff = 8 -- Keep 8 lines above and below the cursor

vim.opt.conceallevel = 0
vim.opt.signcolumn = "yes:1"
vim.opt.termguicolors = false
vim.opt.shell = os.getenv("SHELL")
vim.opt.ignorecase = true -- Ignore case in search
vim.opt.swapfile = false -- Disable swap files
vim.opt.autoindent = true -- Enable auto indentation

vim.opt.completeopt = { "menuone", "popup", "noinsert" } -- Options for completion menu
vim.opt.winborder = "rounded" -- Use rounded borders for windows
vim.opt.hlsearch = false -- Disable highlighting of search results
vim.opt.backup = true
vim.opt.undofile = true

local home = os.getenv("HOME")

vim.opt.backupdir = string.format("%s/.nvim-backup/", home)

local python_cmd = os.getenv("PYTHON") or "python3"
local cmd_shell = os.getenv("CMD_SHELL") or vim.opt.shell

vim.cmd.filetype("plugin indent on") -- Enable filetype detection, plugins, and indentation

vim.cmd('let mapleader = ","')
vim.cmd('map <leader>h :noh<CR>')
vim.keymap.set('n', '<leader>b', ':GitBlameToggle<CR>', { noremap = true })
vim.keymap.set('n', '<Up>', 'gk', { noremap = true })
vim.keymap.set('n', '<Left>', 'gh', { noremap = true })
vim.keymap.set('n', '<Down>', 'gj', { noremap = true })
vim.keymap.set('n', '<Right>', 'gl', { noremap = true })
vim.keymap.set('n', '<C-h>', '<C-w>h')
vim.keymap.set('n', '<C-l>', '<C-w>l')
vim.keymap.set('n', '<C-j>', '<C-w>j')
vim.keymap.set('n', '<C-k>', '<C-w>k')
vim.keymap.set('n', '<C-s>', ':spl<CR>')
vim.keymap.set('n', '<C-s><C-v>', ':vsp<CR>')
vim.keymap.set('n', '<C-s><C-l>', ':vsp<CR>')
vim.keymap.set('n', '<C-s><C-h>', ':vsp<CR>')
vim.keymap.set('n', '<C-s><C-j>', ':spl<CR>')
vim.keymap.set('n', '<C-s><C-k>', ':spl<CR>')
vim.keymap.set('n', '<leader>t', ':wincmd =<CR>')
vim.keymap.set('c', 'wqa', 'wa<CR>:qa<CR>', { noremap = true })
vim.keymap.set('n', '<C-a>', 'gg0vG$')

vim.keymap.set('n', '<C-Right>', '<C-w><S-l>')
vim.keymap.set('n', '<C-Left>', '<C-w><S-h>')
vim.keymap.set('n', '<C-Up>', '<C-w><S-k>')
vim.keymap.set('n', '<C-Down>', '<C-w><S-j>')
vim.keymap.set('n', '<C-=>', '<C-w>=', { noremap = true })
vim.keymap.set('v', '<C-S-c>', '"+y')

vim.keymap.set('v', '<leader>cl', ':s/\\U/\\l&/g', { noremap = true }, { desc = 'Convert to lowercase' })
vim.keymap.set('v', '<leader>cu', ':s/\\l/\\U&/g', { noremap = true }, { desc = 'Convert to uppercase' })

vim.cmd('autocmd TermOpen * setlocal nonumber norelativenumber')

-- local llm_script = string.format("%s/dotfiles/scripts/%s", home, "gemini.py")
local llm_script = string.format("%s/dotfiles/scripts/%s", home, "llm.py")
print(llm_script)

vim.keymap.set('c', 'llm',
    function()
        vim.cmd('new')
        local term_shell = vim.opt.shell
        vim.opt.shell = cmd_shell
        vim.cmd(string.format('terminal %s %s', python_cmd, llm_script))
        vim.cmd("set filetype=markdown")
        vim.opt.shell = term_shell
    end)

function InspectLSP()
  local content = vim.inspect(vim.lsp._enabled_configs.clangd, {depth = nil})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n'))
  vim.api.nvim_set_current_buf(buf)
  vim.bo.filetype = 'lua'
end

-- Copy full path to clipboard
vim.keymap.set('n', '<leader>p', function() vim.fn.setreg('+', vim.fn.expand('%:p')) end)

-- local parser_config = require "nvim-treesitter.parsers".get_parser_configs()
-- parser_config.template_language = {
--     install_info = {
--         url = "~/repos/template/treesitter-parser",
--         files = { "src/parser.c" },
--         generate_requires_npm = true,
--         requires_generate_from_grammar = false,
--     },
--     filetype = "template_language",
-- }

-- Register the filetype
vim.filetype.add({
    extension = {
        tp = "template_language",
    },
})

-- Add timestamp as extension for backup files
vim.api.nvim_create_autocmd('BufWritePre', {
  group = vim.api.nvim_create_augroup('timestamp_backupext', { clear = true }),
  desc = 'Add timestamp to backup extension',
  pattern = '*',
  callback = function()
    vim.opt.backupext = '-' .. vim.fn.strftime('%Y%m%d%H%M')
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  callback = function()
    vim.opt.formatoptions:remove { "o" }
  end,
})

require("lsp")
require('plugins')
-- require('configs')
require('keymaps')
require('gitdiff').setup()
require('autocmds')
-- require('statusline')

