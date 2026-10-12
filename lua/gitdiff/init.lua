local git = require("gitdiff.git")

local M = {}
local api = vim.api

-- name -> { link, cterm fallback } ; fallback is used when termguicolors is off
-- and the linked group has no cterm colors (true for nightfox's Diff* groups)
local HL = {
   GitDiffAdded = { "Added" },
   GitDiffRemoved = { "Removed" },
   GitDiffChanged = { "Changed" },
   GitDiffRenamed = { "Changed" },
   GitDiffConflict = { "DiagnosticWarn" },
   GitDiffDir = { "Directory" },
   GitDiffDim = { "Comment" },
   GitDiffHeader = { "Title" },
   GitDiffRef = { "Constant" },
   GitDiffError = { "ErrorMsg" },
   GitDiffAdd = { "DiffAdd", { ctermbg = 22 } },
   GitDiffChange = { "DiffChange", { ctermbg = 58 } },
   GitDiffDelete = { "DiffDelete", { ctermbg = 52 } },
   GitDiffDeleteLine = { "DiffDelete", { ctermbg = 52 } },
   GitDiffText = { "DiffText", { ctermbg = 94 } },
   GitDiffAddSign = { "Added" },
   GitDiffChangeSign = { "Changed" },
   GitDiffDeleteSign = { "Removed" },
   GitDiffAddNr = { "Added" },
   GitDiffChangeNr = { "Changed" },
   GitDiffDeleteNr = { "Removed" },
}

local function set_highlights()
   for name, spec in pairs(HL) do
      local target = api.nvim_get_hl(0, { name = spec[1], link = false })
      if spec[2] and not vim.o.termguicolors and not target.ctermbg then
         api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, spec[2]))
      else
         api.nvim_set_hl(0, name, { link = spec[1], default = true })
      end
   end
end

local function complete_refs(arg_lead)
   local refs = vim.fn.systemlist({
      "git", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes", "refs/tags",
   })
   if vim.v.shell_error ~= 0 then
      return {}
   end
   table.insert(refs, 1, "HEAD")
   return vim.tbl_filter(function(ref)
      return vim.startswith(ref, arg_lead)
   end, refs)
end

local function complete(arg_lead, cmdline)
   local nargs = #vim.split(vim.trim(cmdline), "%s+")
   if nargs == 1 or (nargs == 2 and not cmdline:match("%s$")) then
      return complete_refs(arg_lead)
   end
   return vim.fn.getcompletion(arg_lead, "file")
end

-- path the user typed (relative to cwd, absolute, or %) -> repo-relative path
local function repo_path(root, p)
   if p:match("^[%%#~$<]") then
      p = vim.fn.expand(p)
   end
   local abs = vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
   local dir = vim.fs.dirname(abs)
   abs = vim.fs.joinpath(vim.uv.fs_realpath(dir) or dir, vim.fs.basename(abs))
   return vim.fs.relpath(root, abs)
end

-- :GitDiff [ref] [file]
local function command(opts)
   local ref, file = opts.fargs[1] or "HEAD", opts.fargs[2]
   if not file then
      return require("gitdiff.tree").open(ref)
   end
   local root, err = git.root(vim.fn.getcwd())
   if not root then
      return vim.notify("gitdiff: " .. (err or "not a git repository"), vim.log.levels.ERROR)
   end
   if not git.validate_ref(ref, root) then
      return vim.notify("gitdiff: unknown revision: " .. ref, vim.log.levels.ERROR)
   end
   local rel = repo_path(root, file)
   if not rel then
      return vim.notify("gitdiff: " .. file .. " is outside " .. root, vim.log.levels.ERROR)
   end
   require("gitdiff.file").open(ref, rel, { root = root, prev_buf = api.nvim_get_current_buf() })
end

function M.setup()
   set_highlights()
   api.nvim_create_autocmd("ColorScheme", {
      group = api.nvim_create_augroup("gitdiff.hl", { clear = true }),
      callback = set_highlights,
   })
   api.nvim_create_user_command("GitDiff", command, {
      nargs = "*",
      complete = complete,
      desc = "Diff the working tree against a ref (folder view, or one file)",
   })
end

return M
