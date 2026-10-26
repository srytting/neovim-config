--- fzf ---
vim.keymap.set("n", "<leader>o", '<cmd>FzfLua files<CR>')
vim.keymap.set("n", "<leader>bf", '<cmd>FzfLua buffers<CR>')
vim.keymap.set("n", "<leader><Tab>", '<cmd>FzfLua tabs<CR>')
vim.keymap.set("n", "<leader>s", '<cmd>FzfLua global<CR>')
vim.keymap.set("n", "<leader>,", '<cmd>FzfLua combine pickers=oldfiles<CR>')
-- grep_project fuzzy-matches over all lines; ctrl-g toggles back to regex live_grep
vim.keymap.set("n", "<leader>f", '<cmd>FzfLua live_grep<CR>')
vim.keymap.set("n", "<leader>c", function()
   -- fuzzy grep scoped to the current file's directory (no subdirectories),
   -- including git-ignored files
   require("fzf-lua").grep({
      search = "",
      cwd = vim.fn.expand("%:p:h"),
      rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096 --no-ignore --max-depth=1 -e",
   })
end)
vim.keymap.set("n", "<leader>C", function()
   -- like <leader>c but recursive into subdirectories
   require("fzf-lua").grep({
      search = "",
      cwd = vim.fn.expand("%:p:h"),
      rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096 --no-ignore -e",
   })
end)
vim.keymap.set("n", "<leader>gs", '<cmd>FzfLua git_status<CR>')
vim.keymap.set("n", "<leader>gdh", '<cmd>GitDiff<CR>')
vim.keymap.set("n", "<leader>gdd", function()
   -- diff against the most recently committed-to origin/develop/* branch
   local res = vim.system({ "git", "for-each-ref", "--sort=-committerdate", "--count=1",
      "--format=%(refname:short)", "refs/remotes/origin/develop/" }, { text = true }):wait()
   local ref = vim.trim(res.stdout or "")
   if res.code ~= 0 or ref == "" then
      return vim.notify("gitdiff: no origin/develop/* branch found", vim.log.levels.ERROR)
   end
   vim.cmd.GitDiff(ref)
end)
vim.keymap.set("n", "<leader>gb", '<cmd>FzfLua git_bcommits<CR>')
vim.keymap.set("n", "<leader>.", '<cmd>FzfLua resume<CR>')
vim.keymap.set("n", "<leader>*", '<cmd>FzfLua grep_cword<CR>')
vim.keymap.set("n", "<leader>*", '<cmd>FzfLua grep_visual<CR>')
vim.keymap.set("n", "<leader>y", '<cmd>FzfLua lsp_document_symbols<CR>')
vim.keymap.set("n", "<leader>D", '<cmd>FzfLua diagnostics_workspace<CR>')
vim.keymap.set('n', '<F12>', "<cmd>FzfLua lsp_references<CR>")

--- LSP ---
vim.keymap.set('n', '<leader>q', vim.lsp.buf.hover, {})
vim.keymap.set('n', '<leader>g', vim.lsp.buf.definition, {})
vim.keymap.set('n', '<F1>', vim.lsp.buf.rename, {})
vim.keymap.set('n', '<leader>w', function()
   -- conform runs the configured CLI formatters (markdown -> mdformat + cbfmt)
   -- and falls back to LSP formatting for every other filetype
   require('conform').format({ lsp_format = 'fallback' })
end)
vim.keymap.set('n', ')', function() vim.diagnostic.jump({ count = 1 }) end)
vim.keymap.set('n', '(', function() vim.diagnostic.jump({ count = -1 }) end)

vim.keymap.set('n', '<leader>d', function()
   vim.diagnostic.open_float({ scope = "cursor" })
end)

vim.keymap.set('n', '<leader>r', function()
   local picked = false
   local lnum = vim.api.nvim_win_get_cursor(0)[1]
   local line = vim.api.nvim_get_current_line()
   vim.lsp.buf.code_action({
      apply = true,
      range = {
         start = { lnum, 0 },
         ["end"] = { lnum, math.max(#line - 1, 0) },
      },
      -- Auto-apply the first quickfix/preferred action, skipping refactor-style ones
      filter = function(action)
         if picked then
            return false
         end
         if action.isPreferred or (action.kind and vim.startswith(action.kind, "quickfix")) then
            picked = true
            return true
         end
         return false
      end,
   })
end)

-- Full code action list (leader-r auto-applies the first quickfix instead)
vim.keymap.set('n', '<leader>R', vim.lsp.buf.code_action, {})
