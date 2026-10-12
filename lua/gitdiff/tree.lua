local git = require("gitdiff.git")

local M = {}

M.config = {
   untracked = true,
   compact_dirs = true,
   auto_refresh = true,
   indent = "   ",
   max_untracked_counted = 2000,
   max_count_bytes = 4 * 1024 * 1024,
}

local api = vim.api
local ns = api.nvim_create_namespace("gitdiff.tree")
local group = api.nvim_create_augroup("gitdiff.tree", { clear = true })
local states = {} -- bufnr -> state

local MARKS = {
   A = { "(+)", "GitDiffAdded" },
   D = { "(-)", "GitDiffRemoved" },
   M = { "(*)", "GitDiffChanged" },
   R = { "(>)", "GitDiffRenamed" },
   U = { "(!)", "GitDiffConflict" },
}

--- parsing ---

local function kind_of(e)
   if e.conflict then return "U" end
   local s = e.status
   if s == "A" or s == "D" then return s end
   if s == "R" or s == "C" then return "R" end
   return "M"
end

-- output of `git diff --raw --numstat -z -M`: all raw records, then all numstat records
local function parse_diff(out)
   local list, by_path = {}, {}
   local function get(path)
      local e = by_path[path]
      if not e then
         e = { path = path }
         by_path[path] = e
         list[#list + 1] = e
      end
      return e
   end
   local toks = vim.split(out, "\0", { plain = true })
   local i, n = 1, #toks
   while i <= n do
      local t = toks[i]
      if t == "" then
         i = i + 1
      elseif t:byte(1) == 58 then -- ":"
         local m1, m2, st = t:match("^:(%d+) (%d+) %x+ %x+ (%u)")
         local e
         if st == "R" or st == "C" then
            e = get(toks[i + 2])
            e.old_path = toks[i + 1]
            i = i + 3
         else
            e = get(toks[i + 1])
            i = i + 2
         end
         if st == "U" then
            e.conflict = true
            e.status = e.status or "U"
         elseif st then
            e.status = st
         end
         if m1 == "160000" or m2 == "160000" then e.submodule = true end
      else
         local a, d, p = t:match("^([%d%-]+)\t([%d%-]+)\t(.*)$")
         if not a then
            i = i + 1
         else
            if p == "" then -- rename: old\0new follow
               p = toks[i + 2]
               i = i + 3
            else
               i = i + 1
            end
            local e = get(p)
            if a == "-" then
               e.binary = true
            else
               e.add, e.del = tonumber(a), tonumber(d)
            end
         end
      end
   end
   for _, e in ipairs(list) do
      e.status = e.status or "M"
   end
   return list, by_path
end

local function count_lines(abs)
   local st = vim.uv.fs_lstat(abs)
   if not st then return nil end
   if st.type == "link" then return 1 end -- git diffs the link target as one line
   if st.type ~= "file" or st.size > M.config.max_count_bytes then return nil end
   if st.size == 0 then return 0 end
   local f = io.open(abs, "rb")
   if not f then return nil end
   local data = f:read("*a")
   f:close()
   if data:sub(1, 8000):find("\0", 1, true) then return nil, true end
   local _, nl = data:gsub("\n", "")
   if data:byte(-1) ~= 10 then nl = nl + 1 end
   return nl
end

local function add_untracked(list, by_path, out, root)
   local paths = vim.split(out, "\0", { plain = true, trimempty = true })
   local count = #paths <= M.config.max_untracked_counted
   local n = 0
   for _, p in ipairs(paths) do
      local nested = p:sub(-1) == "/" -- untracked nested repository
      if nested then p = p:sub(1, -2) end
      if not by_path[p] then
         local e = { path = p, status = "A", untracked = true, submodule = nested or nil, del = 0 }
         if count and not nested then
            e.add, e.binary = count_lines(root .. "/" .. p)
         end
         by_path[p] = e
         list[#list + 1] = e
         n = n + 1
      end
   end
   return n
end

--- tree ---

local function new_dir(name, path, parent)
   return { dir = true, name = name, path = path, parent = parent, children = {}, sub = {} }
end

local function insert(root, e)
   local node, start = root, 1
   while true do
      local s = e.path:find("/", start, true)
      if not s then break end
      local name = e.path:sub(start, s - 1)
      local child = node.sub[name]
      if not child then
         child = new_dir(name, e.path:sub(1, s - 1), node)
         node.sub[name] = child
         node.children[#node.children + 1] = child
      end
      node, start = child, s + 1
   end
   node.children[#node.children + 1] = {
      name = e.path:sub(start), path = e.path, parent = node, entry = e, kind = kind_of(e),
   }
end

-- a/ -> b/ -> c/ with single dir children becomes one "a/b/c/" node
local function compact(dir)
   for idx, c in ipairs(dir.children) do
      if c.dir then
         while #c.children == 1 and c.children[1].dir do
            local only = c.children[1]
            only.name = c.name .. "/" .. only.name
            only.parent = dir
            c = only
         end
         dir.children[idx] = c
         compact(c)
      end
   end
end

local function by_name(a, b)
   if a.dir ~= b.dir then return a.dir == true end
   local la, lb = a.name:lower(), b.name:lower()
   if la ~= lb then return la < lb end
   return a.name < b.name
end

local function aggregate(dir)
   local add, del, nfiles, kind, conflict = 0, 0, 0, nil, false
   for _, c in ipairs(dir.children) do
      if c.dir then
         aggregate(c)
         add, del, nfiles = add + c.add, del + c.del, nfiles + c.nfiles
         conflict = conflict or c.conflict
      else
         local e = c.entry
         add, del, nfiles = add + (e.add or 0), del + (e.del or 0), nfiles + 1
         conflict = conflict or e.conflict == true
      end
      local k = (c.kind == "A" or c.kind == "D") and c.kind or "M"
      if kind == nil then kind = k elseif kind ~= k then kind = "M" end
   end
   dir.add, dir.del, dir.nfiles, dir.conflict = add, del, nfiles, conflict
   dir.kind = conflict and "U" or kind or "M"
   table.sort(dir.children, by_name)
end

-- files[] in display order; dirs get first/last file index for ]f [f
local function index(dir, files)
   dir.first = #files + 1
   for _, c in ipairs(dir.children) do
      if c.dir then
         index(c, files)
      else
         files[#files + 1] = c
         c.index = #files
      end
   end
   dir.last = #files
end

local function build(list)
   local root = new_dir("", "", nil)
   for _, e in ipairs(list) do insert(root, e) end
   if M.config.compact_dirs then compact(root) end
   aggregate(root)
   local files = {}
   index(root, files)
   return root, files
end

local function each_dir(dir, fn)
   for _, c in ipairs(dir.children) do
      if c.dir then
         fn(c)
         each_dir(c, fn)
      end
   end
end

--- render ---

local Line = {}
Line.__index = Line

local function line()
   return setmetatable({ parts = {}, spans = {}, len = 0 }, Line)
end

function Line:add(text, hl)
   if text == "" then return end
   self.parts[#self.parts + 1] = text
   if hl then self.spans[#self.spans + 1] = { self.len, self.len + #text, hl } end
   self.len = self.len + #text
end

function Line:text()
   return table.concat(self.parts)
end

local function disp(s)
   if not s:find("%c") then return s end
   return (s:gsub("%c", function(c) return ("\\x%02x"):format(c:byte()) end))
end

local function counts(l, add, del)
   add, del = add or 0, del or 0
   if add == 0 and del == 0 then return end
   l:add(" (", "GitDiffDim")
   if add > 0 then l:add("+" .. add, "GitDiffAdded") end
   if add > 0 and del > 0 then l:add(" / ", "GitDiffDim") end
   if del > 0 then l:add("-" .. del, "GitDiffRemoved") end
   l:add(")", "GitDiffDim")
end

local function key(node)
   return (node.dir and "d:" or "f:") .. node.path
end

local function render(state, focus)
   local buf = state.buf
   local lines, spans, nodes, keys, cols = {}, {}, {}, {}, {}
   local function push(l, node, col)
      lines[#lines + 1] = l:text()
      spans[#lines] = l.spans
      if node then
         nodes[#lines] = node
         keys[key(node)] = #lines
         cols[#lines] = col
      end
   end

   local h = line()
   h:add("GitDiff ", "GitDiffHeader")
   h:add(state.ref, "GitDiffRef")
   if state.sha then h:add(" " .. state.sha, "GitDiffDim") end
   h:add("  vs working tree", "GitDiffDim")
   push(h)
   local h2 = line()
   h2:add(vim.fn.fnamemodify(state.root, ":~"), "GitDiffDir")
   if state.tree then
      local n = #state.files
      h2:add(("  %d file%s"):format(n, n == 1 and "" or "s"))
      counts(h2, state.tree.add, state.tree.del)
      if (state.n_untracked or 0) > 0 then
         h2:add(("  %d untracked"):format(state.n_untracked), "GitDiffDim")
      end
   end
   h2:add("  ? help", "GitDiffDim")
   push(h2)
   push(line())

   if state.error then
      for _, s in ipairs(vim.split(vim.trim(state.error), "\n")) do
         local l = line()
         l:add(disp(s), "GitDiffError")
         push(l)
      end
   elseif not state.tree then
      local l = line()
      l:add("loading...", "GitDiffDim")
      push(l)
   elseif #state.files == 0 then
      local l = line()
      l:add("no changes", "GitDiffDim")
      push(l)
   else
      local ind = M.config.indent
      local function walk(dir, depth)
         local pad = ind:rep(depth)
         for _, c in ipairs(dir.children) do
            local l = line()
            l:add(pad)
            local mark = MARKS[c.kind]
            l:add(mark[1], mark[2])
            l:add(" ")
            if c.dir then
               l:add(disp(c.name) .. "/", "GitDiffDir")
               counts(l, c.add, c.del)
               push(l, c, #pad)
               if state.expanded[c.path] then walk(c, depth + 1) end
            else
               local e = c.entry
               l:add(disp(c.name), e.conflict and "GitDiffConflict" or nil)
               if e.old_path then
                  local old = e.old_path
                  if vim.fs.dirname(old) == vim.fs.dirname(e.path) then old = vim.fs.basename(old) end
                  l:add(" <- " .. disp(old), "GitDiffDim")
               end
               counts(l, e.add, e.del)
               if e.binary then l:add(" binary", "GitDiffDim") end
               if e.submodule then l:add(" submodule", "GitDiffDim") end
               if e.status == "T" then l:add(" typechange", "GitDiffDim") end
               if e.conflict then l:add(" conflict", "GitDiffConflict") end
               if e.untracked then l:add(" untracked", "GitDiffDim") end
               push(l, c, #pad)
            end
         end
      end
      walk(state.tree, 0)
   end

   -- remember what each window's cursor was on so it can be restored by node key
   local saved = {}
   local cur = api.nvim_get_current_win()
   for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      local view = api.nvim_win_call(win, vim.fn.winsaveview)
      saved[win] = { view = view, node = state.nodes[view.lnum] }
   end

   state.spans, state.nodes, state.keys, state.cols = spans, nodes, keys, cols
   vim.bo[buf].modifiable = true
   api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   vim.bo[buf].modifiable = false

   for win, s in pairs(saved) do
      local lnum
      if win == cur and focus then lnum = keys[focus] end
      local node = s.node
      while not lnum and node do
         lnum = keys[key(node)]
         node = node.parent
      end
      api.nvim_win_call(win, function()
         vim.fn.winrestview(s.view)
         if lnum then api.nvim_win_set_cursor(win, { lnum, cols[lnum] or 0 }) end
      end)
   end
end

api.nvim_set_decoration_provider(ns, {
   on_win = function(_, _, buf)
      return states[buf] ~= nil
   end,
   on_line = function(_, _, buf, row)
      local st = states[buf]
      local sp = st and st.spans[row + 1]
      if not sp then return end
      for _, s in ipairs(sp) do
         api.nvim_buf_set_extmark(buf, ns, row, s[1], {
            end_col = s[2], hl_group = s[3], ephemeral = true, strict = false,
         })
      end
   end,
})

--- refresh ---

function M.refresh(buf)
   local state = states[buf]
   if not state then return end
   state.seq = state.seq + 1
   local seq = state.seq
   state.running = true
   local res = {}
   local pending = M.config.untracked and 3 or 2

   local function done()
      pending = pending - 1
      if pending > 0 then return end
      if states[buf] ~= state or state.seq ~= seq or not api.nvim_buf_is_valid(buf) then return end
      state.running = false
      state.last = vim.uv.now()
      if not res.sha then
         state.error = res.ref_err or ("unknown revision: " .. state.ref)
      elseif not res.diff_ok then
         state.error = res.diff_err
      else
         state.error = nil
         state.sha = res.sha
         local list, by_path = parse_diff(res.diff)
         state.n_untracked = res.untracked and add_untracked(list, by_path, res.untracked, state.root) or 0
         state.tree, state.files = build(list)
      end
      local focus
      if state.reveal and state.files then
         for _, f in ipairs(state.files) do
            if f.path == state.reveal then
               local d = f.parent
               while d and d ~= state.tree do
                  state.expanded[d.path] = true
                  d = d.parent
               end
               focus = key(f)
            end
         end
      end
      state.reveal = nil
      if state.error then
         state.tree, state.files = nil, nil
         vim.notify("gitdiff: " .. vim.trim(state.error), vim.log.levels.ERROR)
      end
      render(state, focus)
   end

   git.validate_ref(state.ref, state.root, function(sha, err)
      res.sha, res.ref_err = sha, err
      done()
   end)
   git.run({
      "diff", "--raw", "--numstat", "-z", "-M", "--no-color", "--no-ext-diff", "--no-relative",
      state.ref, "--",
   }, state.root, function(ok, out, err)
      res.diff_ok, res.diff, res.diff_err = ok, out, err
      done()
   end)
   if M.config.untracked then
      git.run({ "ls-files", "--others", "--exclude-standard", "-z" }, state.root, function(ok, out)
         res.untracked = ok and out or nil
         done()
      end)
   end
end

--- actions ---

local function cursor_node(state)
   return state.nodes[api.nvim_win_get_cursor(0)[1]]
end

local function set_expanded(state, node, open)
   if open == nil then open = not state.expanded[node.path] end
   state.expanded[node.path] = open or nil
   render(state, key(node))
end

local function open_file(state, node, how)
   local e = node.entry
   if how == "vsplit" then
      vim.cmd("vsplit")
   elseif how == "tab" then
      vim.cmd("tab split")
   end
   require("gitdiff.file").open(state.ref, e.path, {
      status = e.status,
      old_path = e.old_path,
      conflict = e.conflict,
      binary = e.binary,
      submodule = e.submodule,
      untracked = e.untracked,
      root = state.root,
      tree_buf = state.buf,
   })
end

local function jump_file(state, step)
   local files = state.files
   if not files or #files == 0 then return end
   step = step * vim.v.count1
   local node = cursor_node(state)
   local target
   if not node then
      target = step > 0 and step or #files + step + 1
   elseif node.dir then
      target = step > 0 and node.first + step - 1 or node.first + step
   else
      target = node.index + step
   end
   local f = files[math.max(1, math.min(#files, target))]
   local p = f.parent
   while p and p ~= state.tree do
      state.expanded[p.path] = true
      p = p.parent
   end
   render(state, key(f))
end

local KEYS -- defined below, used by help

local actions = {}

function actions.select(state)
   local node = cursor_node(state)
   if not node then return end
   if node.dir then set_expanded(state, node) else open_file(state, node) end
end

function actions.toggle(state)
   local node = cursor_node(state)
   if not node then return end
   if node.dir then
      set_expanded(state, node)
   elseif node.parent ~= state.tree then
      set_expanded(state, node.parent, false)
   end
end

function actions.expand(state)
   local node = cursor_node(state)
   if not node then return end
   if not node.dir then return open_file(state, node) end
   if state.expanded[node.path] then
      render(state, key(node.children[1]))
   else
      set_expanded(state, node, true)
   end
end

function actions.collapse(state)
   local node = cursor_node(state)
   if not node then return end
   if node.dir and state.expanded[node.path] then
      set_expanded(state, node, false)
   elseif node.parent and node.parent ~= state.tree then
      set_expanded(state, node.parent, false)
   end
end

function actions.expand_all(state)
   if not state.tree then return end
   each_dir(state.tree, function(d) state.expanded[d.path] = true end)
   local node = cursor_node(state)
   render(state, node and key(node))
end

function actions.collapse_all(state)
   local node = cursor_node(state)
   while node and node.parent and node.parent ~= state.tree do node = node.parent end
   state.expanded = {}
   render(state, node and key(node))
end

function actions.next_file(state) jump_file(state, 1) end
function actions.prev_file(state) jump_file(state, -1) end

function actions.vsplit(state)
   local node = cursor_node(state)
   if node and not node.dir then open_file(state, node, "vsplit") end
end

function actions.tab(state)
   local node = cursor_node(state)
   if node and not node.dir then open_file(state, node, "tab") end
end

function actions.edit(state)
   local node = cursor_node(state)
   if not node or node.dir then return end
   if node.entry.status == "D" then
      return vim.notify("gitdiff: file is deleted in the working tree", vim.log.levels.WARN)
   end
   vim.cmd.edit(vim.fn.fnameescape(state.root .. "/" .. node.path))
end

function actions.refresh(state) M.refresh(state.buf) end

function actions.close(state)
   local buf = state.buf
   local alt = vim.fn.bufnr("#")
   if alt > 0 and alt ~= buf and api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
      api.nvim_win_set_buf(0, alt)
   end
   api.nvim_buf_delete(buf, { force = true })
end

function actions.help()
   local chunks = {}
   for _, k in ipairs(KEYS) do
      chunks[#chunks + 1] = { ("%-14s"):format(table.concat(k[1], " ")), "Special" }
      chunks[#chunks + 1] = { k[3] .. "\n" }
   end
   api.nvim_echo(chunks, false, {})
end

KEYS = {
   { { "<CR>" }, "select", "toggle folder / open file diff" },
   { { "<Tab>", "za" }, "toggle", "toggle folder" },
   { { "l", "zo" }, "expand", "expand folder / open file diff" },
   { { "h", "zc" }, "collapse", "collapse folder / go to parent" },
   { { "zR" }, "expand_all", "expand all" },
   { { "zM" }, "collapse_all", "collapse all" },
   { { "]f" }, "next_file", "next file" },
   { { "[f" }, "prev_file", "previous file" },
   { { "<C-v>" }, "vsplit", "open file diff in vsplit" },
   { { "<C-t>" }, "tab", "open file diff in new tab" },
   { { "e" }, "edit", "edit working tree file" },
   { { "R" }, "refresh", "refresh" },
   { { "q" }, "close", "close" },
   { { "?", "g?" }, "help", "show keymaps" },
}

--- buffer lifecycle ---

local function create(name, ref, root)
   local buf = api.nvim_create_buf(true, false)
   api.nvim_buf_set_name(buf, name)
   local bo = vim.bo[buf]
   bo.buftype = "nofile"
   bo.bufhidden = "hide"
   bo.swapfile = false
   bo.undolevels = -1
   bo.modifiable = false

   local state = {
      buf = buf, ref = ref, root = root, seq = 0,
      expanded = {}, spans = {}, nodes = {}, keys = {}, cols = {},
   }
   states[buf] = state

   for _, k in ipairs(KEYS) do
      for _, lhs in ipairs(k[1]) do
         vim.keymap.set("n", lhs, function()
            local s = states[buf]
            if s then actions[k[2]](s) end
         end, { buffer = buf, nowait = true, silent = true, desc = "gitdiff: " .. k[3] })
      end
   end

   api.nvim_create_autocmd("BufWinEnter", {
      group = group,
      buffer = buf,
      callback = function()
         vim.opt_local.wrap = false
         vim.opt_local.list = false
         vim.opt_local.spell = false
         vim.opt_local.foldenable = false
         vim.opt_local.cursorline = true
      end,
   })
   api.nvim_create_autocmd("BufEnter", {
      group = group,
      buffer = buf,
      callback = function()
         local s = states[buf]
         if s and M.config.auto_refresh and not s.running and s.last and vim.uv.now() - s.last > 1000 then
            M.refresh(buf)
         end
      end,
   })
   api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      callback = function() states[buf] = nil end,
   })

   render(state)
   bo.filetype = "gitdiff"
   return buf
end

-- opts.reveal: repo-relative path to expand to and put the cursor on
function M.open(ref, opts)
   ref = (ref and ref ~= "") and ref or "HEAD"
   local root, err = git.root(vim.fn.getcwd())
   if not root then
      vim.notify("gitdiff: " .. ((err and err ~= "") and err or "not a git repository"), vim.log.levels.ERROR)
      return
   end
   local name = "gitdiff://" .. ref
   local buf
   for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_get_name(b) == name then
         buf = b
         break
      end
   end
   if buf and not states[buf] then
      api.nvim_buf_delete(buf, { force = true })
      buf = nil
   end
   if not buf then
      buf = create(name, ref, root)
   elseif states[buf].root ~= root then
      local s = states[buf]
      s.root, s.expanded, s.tree, s.files, s.sha = root, {}, nil, nil, nil
      render(s)
   end
   states[buf].reveal = opts and opts.reveal
   -- start the job before showing the buffer so BufEnter's auto-refresh sees running=true
   M.refresh(buf)
   api.nvim_win_set_buf(0, buf)
end

return M
