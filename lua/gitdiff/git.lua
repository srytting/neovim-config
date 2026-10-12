local M = {}

function M.root(cwd)
   local ok, res = pcall(function()
      return vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd, text = true }):wait()
   end)
   if not ok then return nil, tostring(res) end
   if res.code ~= 0 then return nil, vim.trim(res.stderr or "") end
   return vim.trim(res.stdout)
end

-- cb(ok, stdout, stderr, code) on the main loop; stdout is raw (safe for -z)
function M.run(args, cwd, cb)
   local cmd = { "git", "--no-optional-locks", "-c", "core.quotepath=false" }
   vim.list_extend(cmd, args)
   local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = false }, function(res)
      vim.schedule(function()
         cb(res.code == 0, res.stdout or "", res.stderr or "", res.code)
      end)
   end)
   if not ok then
      vim.schedule(function() cb(false, "", tostring(err), -1) end)
   end
end

-- async with cb(short_sha|nil, err); sync (returns sha, err) when cb is nil
function M.validate_ref(ref, cwd, cb)
   if type(ref) ~= "string" or ref == "" or ref:sub(1, 1) == "-" then
      if cb then vim.schedule(function() cb(nil, "invalid ref") end) end
      return nil, "invalid ref"
   end
   local args = { "rev-parse", "--verify", "--quiet", "--short", ref .. "^{commit}" }
   if not cb then
      local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
      if res.code ~= 0 then return nil, "unknown revision: " .. ref end
      return vim.trim(res.stdout)
   end
   M.run(args, cwd, function(ok, out)
      if ok then cb(vim.trim(out)) else cb(nil, "unknown revision: " .. ref) end
   end)
end

-- Fetch <ref>:<path> with smudge/eol filters so it compares to the working tree.
-- cb(blob, err) on the main loop. blob == nil and err == nil: path absent at ref.
-- blob = { mode, size, data, binary } or { mode, size, too_large = true }
function M.show(root, ref, path, opts, cb)
   opts = opts or {}
   local function done(blob, err)
      vim.schedule(function() cb(blob, err) end)
   end
   vim.system({ "git", "--literal-pathspecs", "ls-tree", "-l", "-z", ref, "--", path },
      { cwd = root, text = false }, function(r)
         if r.code ~= 0 then
            return done(nil, vim.trim(r.stderr or ""))
         end
         local mode, typ, oid, size = (r.stdout or ""):match("^(%d+) (%a+) (%x+)%s+(%S+)\t")
         if not mode then
            return done(nil, nil)
         end
         if typ ~= "blob" then
            return done(nil, path .. " is a " .. typ .. " at " .. ref)
         end
         size = tonumber(size) or 0
         if opts.max_bytes and size > opts.max_bytes then
            return done({ mode = mode, size = size, too_large = true })
         end
         vim.system({ "git", "cat-file", "--filters", "--path=" .. path, oid },
            { cwd = root, text = false }, function(c)
               if c.code ~= 0 then
                  return done(nil, vim.trim(c.stderr or ""))
               end
               local data = c.stdout or ""
               done({ mode = mode, size = size, data = data,
                  binary = data:sub(1, 8000):find("\0", 1, true) ~= nil })
            end)
      end)
end

return M
