local git = require("gitdiff.git")

local M = {}
local api = vim.api

local ns = api.nvim_create_namespace("gitdiff.file")
local ns_removed = api.nvim_create_namespace("gitdiff.file.removed")
local group = api.nvim_create_augroup("gitdiff.file", { clear = true })

M.config = {
   show_removed = false, -- initial state; toggling makes it sticky for the session
   word_diff = false,
   max_bytes = 8 * 1024 * 1024,
}

local state = {} -- buf -> { p = params, d = diff data, show_removed = bool, winbar = string }
local by_name = {} -- buffer name -> buf
local pending = {} -- buffer name -> token of newest request

local function notify(msg, level)
   vim.notify("gitdiff: " .. msg, level or vim.log.levels.WARN)
end

local function is_binary(data)
   return data:sub(1, 8000):find("\0", 1, true) ~= nil
end

local function split_lines(data)
   local info = { eol = true, crlf = false, lines = {} }
   if data == "" then
      return info
   end
   info.eol = data:sub(-1) == "\n"
   if data:find("\r\n", 1, true) then
      info.crlf = true
      data = data:gsub("\r\n", "\n")
   end
   local lines = vim.split(data, "\n", { plain = true })
   if info.eol then
      lines[#lines] = nil
   end
   info.lines = lines
   return info
end

local function loaded_buf(abs)
   for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and api.nvim_buf_get_name(b) == abs then
         return b
      end
   end
end

-- nil when the file does not exist in the working tree
local function read_worktree(abs)
   local b = loaded_buf(abs)
   if b and vim.bo[b].modified then
      return {
         lines = api.nvim_buf_get_lines(b, 0, -1, false),
         eol = vim.bo[b].eol or vim.bo[b].fixeol,
         crlf = vim.bo[b].fileformat == "dos",
         unsaved = true,
      }
   end
   local stat = vim.uv.fs_lstat(abs)
   if not stat then
      return nil
   end
   if stat.type == "link" then
      -- git stores a symlink as its target path, so compare targets
      return { lines = { vim.uv.fs_readlink(abs) or "" }, eol = false, crlf = false }
   end
   if stat.type ~= "file" then
      return { err = abs .. " is not a regular file" }
   end
   if stat.size > M.config.max_bytes then
      return { too_large = true }
   end
   local fd = io.open(abs, "rb")
   if not fd then
      return { err = "cannot read " .. abs }
   end
   local data = fd:read("*a")
   fd:close()
   if is_binary(data) then
      return { binary = true }
   end
   return split_lines(data)
end

local function compute(old, new)
   local a = #old > 0 and table.concat(old, "\n") .. "\n" or ""
   local b = #new > 0 and table.concat(new, "\n") .. "\n" or ""
   local idx = vim.text.diff(a, b, { result_type = "indices", algorithm = "histogram", indent_heuristic = true })
   local hunks, kinds, stats = {}, {}, { added = 0, removed = 0 }
   for _, i in ipairs(idx) do
      local sa, ca, sb, cb = i[1], i[2], i[3], i[4]
      local h = { type = ca == 0 and "add" or cb == 0 and "delete" or "change",
         start = sb, added = cb, removed = ca, old = {} }
      for k = 0, ca - 1 do
         h.old[#h.old + 1] = old[sa + k]
      end
      for k = 0, cb - 1 do
         kinds[sb + k] = (h.type == "change" and k < ca) and "change" or "add"
      end
      stats.added = stats.added + cb
      stats.removed = stats.removed + ca
      -- anchor: line the removed virt_lines/sign attach to; top: navigation target
      if cb > 0 then
         h.anchor, h.above = sb, true
      elseif sb < #new then
         h.anchor, h.above = sb + 1, true
      else
         h.anchor, h.above = math.max(sb, 1), false
      end
      h.top = h.anchor
      hunks[#hunks + 1] = h
   end
   return hunks, kinds, stats
end

local function tokens(s)
   local toks, pos = {}, 1
   while pos <= #s do
      local e = select(2, s:find("^[%w_\128-\255]+", pos)) or select(2, s:find("^%s+", pos)) or pos
      toks[#toks + 1] = { pos, e }
      pos = e + 1
   end
   return toks
end

local function word_diff(buf, old, new, row)
   if not old or not new or #old > 1000 or #new > 1000 then
      return
   end
   local ot, nt = tokens(old), tokens(new)
   if #ot == 0 or #nt == 0 then
      return
   end
   local function join(s, t)
      local out = {}
      for i, r in ipairs(t) do
         out[i] = s:sub(r[1], r[2])
      end
      return table.concat(out, "\n") .. "\n"
   end
   for _, h in ipairs(vim.text.diff(join(old, ot), join(new, nt), { result_type = "indices" })) do
      if h[4] > 0 then
         local s, e = nt[h[3]][1], nt[h[3] + h[4] - 1][2]
         api.nvim_buf_set_extmark(buf, ns, row, s - 1, { end_col = e, hl_group = "GitDiffText", priority = 20 })
      end
   end
end

local function expand_tabs(s, ts)
   if not s:find("\t", 1, true) then
      return s
   end
   local out = ""
   for seg, tab in s:gmatch("([^\t]*)(\t?)") do
      out = out .. seg
      if tab ~= "" then
         out = out .. string.rep(" ", ts - api.nvim_strwidth(out) % ts)
      end
   end
   return out
end

local function removed_virt(h, width, ts)
   local vl = {}
   for _, l in ipairs(h.old) do
      local text = expand_tabs(l, ts)
      vl[#vl + 1] = { { text .. string.rep(" ", math.max(width - api.nvim_strwidth(text), 0)), "GitDiffDeleteLine" } }
   end
   return vl
end

local function render_removed(buf)
   local st = state[buf]
   api.nvim_buf_clear_namespace(buf, ns_removed, 0, -1)
   if not st.show_removed or st.d.deleted then
      return
   end
   local width, ts = vim.o.columns, vim.bo[buf].tabstop
   for _, h in ipairs(st.d.hunks) do
      if h.removed > 0 then
         if h.virt_width ~= width then
            h.virt, h.virt_width = removed_virt(h, width, ts), width
         end
         api.nvim_buf_set_extmark(buf, ns_removed, h.anchor - 1, 0, { virt_lines = h.virt, virt_lines_above = h.above })
      end
   end
end

local function decorate(buf, st)
   api.nvim_buf_clear_namespace(buf, ns, 0, -1)
   local d = st.d
   if d.deleted then
      for i = 1, #d.lines do
         api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "GitDiffDelete", sign_text = "┃",
            sign_hl_group = "GitDiffDeleteSign", number_hl_group = "GitDiffDeleteNr", priority = 10 })
      end
      return
   end
   for lnum, kind in pairs(d.kinds) do
      local g = kind == "add" and "GitDiffAdd" or "GitDiffChange"
      api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { line_hl_group = g, sign_text = "┃",
         sign_hl_group = g .. "Sign", number_hl_group = g .. "Nr", priority = 10 })
   end
   for _, h in ipairs(d.hunks) do
      if h.removed > 0 then
         api.nvim_buf_set_extmark(buf, ns, h.anchor - 1, 0, {
            virt_text = { { ("  -%d line%s"):format(h.removed, h.removed == 1 and "" or "s"), "GitDiffDeleteSign" } },
            virt_text_pos = "eol",
         })
      end
      if h.type == "delete" then
         api.nvim_buf_set_extmark(buf, ns, h.anchor - 1, 0, { sign_text = h.above and "▔" or "▁",
            sign_hl_group = "GitDiffDeleteSign", number_hl_group = "GitDiffDeleteNr", priority = 10 })
      elseif h.type == "change" and M.config.word_diff then
         for k = 0, math.min(h.removed, h.added) - 1 do
            word_diff(buf, h.old[k + 1], d.lines[h.start + k], h.start + k - 1)
         end
      end
   end
end

local function winbar_text(p, d)
   local function esc(s)
      return (s:gsub("%%", "%%%%"))
   end
   local t = { "%#GitDiffHeader# ", esc(p.path) }
   if p.old_path ~= p.path then
      t[#t + 1] = "%#Comment# ← " .. esc(p.old_path)
   end
   local target = d.deleted and "deleted" or d.unsaved and "buffer [+]" or "working tree"
   t[#t + 1] = "%#Comment#  " .. esc(p.ref) .. " → " .. target .. "  "
   t[#t + 1] = "%#GitDiffAddSign#+" .. d.stats.added .. " %#GitDiffDeleteSign#-" .. d.stats.removed
   local flags = {}
   if d.new_file then flags[#flags + 1] = "new file" end
   if d.crlf_changed then flags[#flags + 1] = "line endings changed" end
   if d.eol_changed then flags[#flags + 1] = "newline at EOF changed" end
   if #flags > 0 then
      t[#t + 1] = "%#Comment#  [" .. table.concat(flags, ", ") .. "]"
   end
   t[#t + 1] = "%#Comment#  g? help"
   return table.concat(t) .. "%*"
end

local function set_winbar(win, text)
   api.nvim_set_option_value("winbar", text, { win = win, scope = "local" })
end

local function load(p, cb)
   git.show(p.root, p.ref, p.old_path, { max_bytes = M.config.max_bytes }, function(blob, err)
      if err then
         return cb(nil, err)
      end
      local new = read_worktree(p.abs)
      if (blob and blob.too_large) or (new and new.too_large) then
         return cb(nil, p.path .. " is larger than max_bytes")
      end
      if (blob and blob.binary) or (new and new.binary) then
         return cb(nil, "binary file " .. p.path .. " differs")
      end
      if new and new.err then
         return cb(nil, new.err)
      end
      if not blob and not new then
         return cb(nil, p.path .. " exists neither at " .. p.ref .. " nor in the working tree")
      end
      local old = blob and split_lines(blob.data) or { lines = {}, eol = true, crlf = false }
      local d = { new_file = blob == nil, deleted = new == nil, unsaved = new and new.unsaved }
      if d.deleted then
         d.lines, d.kinds = old.lines, {}
         d.hunks = { { type = "delete", top = 1, anchor = 1, start = 0, added = 0, removed = #old.lines, old = {} } }
         d.stats = { added = 0, removed = #old.lines }
      else
         d.lines = new.lines
         d.hunks, d.kinds, d.stats = compute(old.lines, new.lines)
         if blob then
            d.crlf_changed = old.crlf ~= new.crlf
            d.eol_changed = #old.lines > 0 and #new.lines > 0 and old.eol ~= new.eol
         end
      end
      d.crlf = (new or old).crlf
      cb(d)
   end)
end

local function render(buf, p, d)
   local cursors = {}
   for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      cursors[w] = api.nvim_win_get_cursor(w)
   end
   vim.bo[buf].modifiable = true
   api.nvim_buf_set_lines(buf, 0, -1, false, d.lines)
   vim.bo[buf].fileformat = d.crlf and "dos" or "unix"
   vim.bo[buf].modifiable = false
   vim.bo[buf].modified = false
   local prev = state[buf]
   local show_removed = M.config.show_removed
   if prev then show_removed = prev.show_removed end
   local st = { p = p, d = d, show_removed = show_removed }
   st.winbar = winbar_text(p, d)
   state[buf] = st
   decorate(buf, st)
   render_removed(buf)
   local n = api.nvim_buf_line_count(buf)
   for w, c in pairs(cursors) do
      pcall(api.nvim_win_set_cursor, w, { math.min(c[1], n), c[2] })
      set_winbar(w, st.winbar)
   end
end

-- with removed lines shown, virt_lines above line 1 need topfill to be visible
local function reveal_top(buf)
   local st = state[buf]
   local h = st.d.hunks[1]
   if st.show_removed and not st.d.deleted and h and h.anchor == 1 and h.above and h.removed > 0 then
      local view = vim.fn.winsaveview()
      if view.topline == 1 then
         view.topfill = h.removed
         vim.fn.winrestview(view)
      end
   end
end

local function jump(buf, dir)
   local hunks = state[buf].d.hunks
   if #hunks == 0 then
      return notify("no changes", vim.log.levels.INFO)
   end
   local pos = api.nvim_win_get_cursor(0)[1]
   local target
   for _ = 1, vim.v.count1 do
      local from, nxt = target or pos, nil
      if dir > 0 then
         for _, h in ipairs(hunks) do
            if h.top > from then nxt = h.top break end
         end
      else
         for i = #hunks, 1, -1 do
            if hunks[i].top < from then nxt = hunks[i].top break end
         end
      end
      if not nxt and vim.o.wrapscan then
         nxt = dir > 0 and hunks[1].top or hunks[#hunks].top
      end
      if not nxt then break end
      target = nxt
   end
   if not target then return end
   vim.cmd("normal! m'")
   api.nvim_win_set_cursor(0, { target, 0 })
   vim.cmd("normal! ^zv")
   if target == 1 then reveal_top(buf) end
end

function M.toggle_removed(buf)
   buf = buf or api.nvim_get_current_buf()
   local st = state[buf]
   if not st then return end
   if st.d.deleted then
      return notify("file is deleted; every line shown is a removed line", vim.log.levels.INFO)
   end
   st.show_removed = not st.show_removed
   M.config.show_removed = st.show_removed
   render_removed(buf)
   reveal_top(buf)
end

local function wipe_if_hidden(buf)
   if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      api.nvim_buf_delete(buf, { force = true })
   end
end

local function close(buf)
   local prev = state[buf] and state[buf].p.prev_buf
   local win = api.nvim_get_current_win()
   if prev and prev ~= buf and api.nvim_buf_is_valid(prev) then
      api.nvim_win_set_buf(win, prev)
   elseif #api.nvim_tabpage_list_wins(0) > 1 then
      api.nvim_win_close(win, false)
   else
      vim.cmd.enew()
   end
   wipe_if_hidden(buf)
end

local function to_tree(buf)
   local p = state[buf].p
   require("gitdiff.tree").open(p.ref, { reveal = p.path })
   wipe_if_hidden(buf)
end

local function open_real(buf)
   local st = state[buf]
   if st.d.deleted then
      return notify(st.p.path .. " no longer exists in the working tree")
   end
   local pos = api.nvim_win_get_cursor(0)
   vim.cmd.edit(vim.fn.fnameescape(st.p.abs))
   pcall(api.nvim_win_set_cursor, 0, pos)
   vim.cmd("normal! zv")
end

local help = {
   "]c / [c  next / previous hunk",
   "dr       toggle removed lines",
   "<CR> gf  open working-tree file at this line",
   "-        folder view",
   "R        refresh",
   "q        back",
}

local function create_buffer(name)
   local buf = api.nvim_create_buf(false, true) -- nofile, bufhidden=hide, noswapfile
   api.nvim_buf_set_name(buf, name)
   vim.bo[buf].undolevels = -1
   by_name[name] = buf
   local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "gitdiff: " .. desc })
   end
   map("]c", function() jump(buf, 1) end, "next hunk")
   map("[c", function() jump(buf, -1) end, "previous hunk")
   map("dr", function() M.toggle_removed(buf) end, "toggle removed lines")
   map("q", function() close(buf) end, "back")
   map("-", function() to_tree(buf) end, "folder view")
   map("<CR>", function() open_real(buf) end, "open file")
   map("gf", function() open_real(buf) end, "open file")
   map("R", function() M.refresh(buf) end, "refresh")
   map("g?", function() vim.notify(table.concat(help, "\n")) end, "help")

   api.nvim_create_autocmd("BufWinEnter", { group = group, buffer = buf, callback = function()
      if state[buf] then set_winbar(api.nvim_get_current_win(), state[buf].winbar) end
   end })
   api.nvim_create_autocmd("BufWinLeave", { group = group, buffer = buf, callback = function()
      local text = state[buf] and state[buf].winbar
      local wins = vim.fn.win_findbuf(buf)
      vim.schedule(function()
         for _, w in ipairs(wins) do
            if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) ~= buf and vim.wo[w].winbar == text then
               set_winbar(w, "")
            end
         end
      end)
   end })
   api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = function()
      state[buf] = nil
      by_name[name] = nil
   end })
   return buf
end

-- path: repo-relative. opts: root, old_path, status (advisory), win, prev_buf, lnum
function M.open(ref, path, opts)
   opts = opts or {}
   local root = opts.root or git.root(vim.fn.getcwd())
   if not root then
      return notify("not inside a git repository", vim.log.levels.ERROR)
   end
   local win = opts.win or api.nvim_get_current_win()
   local from = state[api.nvim_win_get_buf(win)]
   local p = {
      ref = ref,
      path = path,
      old_path = opts.old_path or path,
      root = root,
      abs = vim.fs.joinpath(root, path),
      prev_buf = opts.prev_buf or (from and from.p.prev_buf) or api.nvim_win_get_buf(win),
      name = "gitdiff://" .. ref .. "/" .. path,
   }
   local token = {}
   pending[p.name] = token
   load(p, function(d, err)
      if pending[p.name] ~= token then return end
      pending[p.name] = nil
      if not d then return notify(err) end
      local buf = by_name[p.name]
      if not (buf and api.nvim_buf_is_valid(buf)) then
         buf = create_buffer(p.name)
      end
      render(buf, p, d)
      if not api.nvim_win_is_valid(win) then
         win = api.nvim_get_current_win()
      end
      api.nvim_win_set_buf(win, buf)
      api.nvim_win_call(win, function()
         -- FileType autocmds (treesitter, folds) act on the current buffer/window
         local ft = vim.filetype.match({ filename = p.abs, contents = d.lines }) or ""
         if vim.bo[buf].filetype ~= ft then
            vim.bo[buf].filetype = ft
         end
         local lnum = opts.lnum or (d.hunks[1] and d.hunks[1].top) or 1
         api.nvim_win_set_cursor(win, { math.min(lnum, api.nvim_buf_line_count(buf)), 0 })
         vim.cmd("normal! zvzz")
         if lnum == 1 then reveal_top(buf) end
      end)
   end)
end

function M.refresh(buf)
   buf = buf or api.nvim_get_current_buf()
   local st = state[buf]
   if not st then return end
   local p = st.p
   local token = {}
   pending[p.name] = token
   load(p, function(d, err)
      if pending[p.name] ~= token or not api.nvim_buf_is_valid(buf) then return end
      pending[p.name] = nil
      if not d then return notify(err) end
      render(buf, p, d)
   end)
end

api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(args)
   local name = api.nvim_buf_get_name(args.buf)
   for b, st in pairs(state) do
      if st.p.abs == name then M.refresh(b) end
   end
end })

api.nvim_create_autocmd("VimResized", { group = group, callback = function()
   for b, st in pairs(state) do
      if st.show_removed then render_removed(b) end
   end
end })

return M
