-- ▾▾▾ Setup ▾▾▾ --
local capabilities = vim.lsp.protocol.make_client_capabilities()

capabilities.textDocument.foldingRange = {
   dynamicRegistration = true,
   lineFoldingOnly = true,
}

capabilities.textDocument.semanticTokens.multilineTokenSupport = true
capabilities.textDocument.completion.completionItem.snippetSupport = true

vim.lsp.config("*", {
   capabilities = capabilities
})

-- Disable the default keybinds
for _, bind in ipairs({ "grn", "gra", "gri", "grr", "grt" }) do
   pcall(vim.keymap.del, "n", bind)
end
-- ^^^ Setup ^^^ --

-- ▾▾▾ C++ ▾▾▾ --
vim.lsp.config.clangd = {
   cmd = {
      "clangd",
      "--background-index",
      "--clang-tidy",
      "-j=8",
   },
   filetypes = { "c", "cpp", "objc", "objcpp", "cuda", "proto" },
   capabilities = vim.tbl_deep_extend('force', capabilities, {
      offsetEncoding = { "utf-16" },
   }),
   root_markers = {
      "compile_commands.json",
      ".clangd",
      ".clang-tidy",
      ".clang-format",
      "CMakeLists.txt",
      "compile_flags.txt",
      "configure.ac",
      ".git",
      vim.uv.cwd(),
   },
}
-- ^^^ C++ ^^^ --

-- ▾▾▾ Markdown Oxide ▾▾▾ --
vim.lsp.config('markdown_oxide', {
   cmd = { "markdown-oxide" },
   capabilities = vim.tbl_deep_extend('force', capabilities, {
      workspace = {
         didChangeWatchedFiles = {
            dynamicRegistration = true,
         },
      },
   }),
   filetypes = { 'markdown' },
   root_markers = { '.moxide.toml', '.obsidian', '.git' },
})
vim.lsp.enable("markdown_oxide")
-- ^^^ Markdown Oxide ^^^ --

-- ▾▾▾ CMake ▾▾▾ --

vim.lsp.config('cmake', {
   cmd = { "neocmakelsp", "stdio" },
   capabilities = capabilities,
   init_options = {
      lint = { enable = true },
      format = { enable = true }
   },
   filetypes = { 'cmake' },
   root_markers = { 'CMakeLists.txt' },
   single_file_support = true,

})

-- ^^^ CMake ^^^ --

-- ▾▾▾ json ▾▾▾ --
vim.lsp.config('jsonls', {
   cmd = { "vscode-json-language-server" },
   capabilities = capabilities,
   filetypes = { 'json' },
   root_markers = {},
})
-- ^^^ json ^^^ --

-- ▾▾▾ Rust ▾▾▾ --
vim.lsp.config.rust_analyzer = {
   filetypes = { "rust" },
   cmd = { "rust-analyzer" },
   workspace_required = true,
   root_dir = function(buf, cb)
      local root = vim.fs.root(buf, { "Cargo.toml", "rust-project.json" })
      local out = vim.system({ "cargo", "metadata", "--no-deps", "--format-version", "1" }, { cwd = root }):wait()
      if out.code ~= 0 then
         return cb(root)
      end
      local ok, result = pcall(vim.json.decode, out.stdout)
      if ok and result.workspace_root then
         return cb(result.workspace_root)
      end
      return cb(root)
   end,
   settings = {
      autoformat = false,
      diagnosticMode = {
         enable = false
      },
      ["rust-analyzer"] = {
         check = {
            command = "check",
         },
         inlayHints = {
            enable = false
         }
      },
   },
}
vim.lsp.enable("rust_analyzer")
-- ^^^ Rust ^^^ --

-- ▾▾▾ Lua ▾▾▾ --
vim.lsp.config.lua_ls = {
   cmd = { "lua-language-server" },
   filetypes = { "lua" },
   root_markers = { ".luarc.json", ".git", vim.uv.cwd() },
   settings = {
      Lua = {
         telemetry = {
            enable = false,
         },
         format = {
            enable = true,
            defaultConfig = {
               indent_style = "space",
               indent_size = "3",
            },
         },
      },
   },
}
vim.lsp.enable("lua_ls")
-- ^^^ Lua ^^^ --

-- ▾▾▾ Python ▾▾▾ --
vim.lsp.config.basedpyright = {
   name = "basedpyright",
   filetypes = { "python" },
   cmd = { "basedpyright-langserver", "--stdio" },
   root_markers = { "pyrightconfig.json", "pyproject.toml" },
   settings = {
      basedpyright = {
         disableOrganizeImports = true,
         analysis = {
            autoSearchPaths = true,
            autoImportCompletions = true,
            useLibraryCodeForTypes = true,
            diagnosticMode = "openFilesOnly",
            typeCheckingMode = "basic",
            reportWildcardImportFromLibrary = false,
            reportMissingTypeStubs = false,
            pythonVersion = "3.14",
            inlayHints = {
               variableTypes = true,
               callArgumentNames = true,
               functionReturnTypes = true,
               genericTypes = false,
            },
         },
      },
   },
}
-- ^^^ Python ^^^ --

-- ▾▾▾ Bash ▾▾▾ --
vim.lsp.config.bashls = {
   cmd = { "bash-language-server", "start" },
   filetypes = { "bash", "sh", "zsh" }
}
vim.lsp.enable("bashls")
-- ^^^ Bash ^^^ --

-- vim.lsp.config.beautysh = {
--     cmd = { "beautysh" },
--     filetypes = { "bash", "sh", "zsh" }
-- }
-- vim.lsp.enable("beautysh")
-- ^^^ Bash ^^^ --

-- ▾▾▾ HTML ▾▾▾ --
vim.lsp.config.htmlls = {
   cmd = { "vscode-html-language-server", "--stdio" },
   filetypes = { "html" },
   root_markers = { "package.json", ".git" },
   init_options = {
      configurationSection = { "html", "css", "javascript" },
      embeddedLanguages = {
         css = true,
         javascript = true,
      },
      provideFormatter = true,
   },
}
-- ^^^ HTML ^^^ --

-- ▾▾▾ Go ▾▾▾ --
vim.lsp.config.gopls = {
   cmd = { "gopls" },
   filetypes = { "go", "gotempl", "gowork", "gomod" },
   root_markers = { ".git", "go.mod", "go.work", vim.uv.cwd() },
   settings = {
      gopls = {
         completeUnimported = true,
         usePlaceholders = true,
         analyses = {
            unusedparams = true,
         },
         ["ui.inlayhint.hints"] = {
            compositeLiteralFields = true,
            constantValues = true,
            parameterNames = true,
            rangeVariableTypes = true,
         },
      },
   },
}
vim.lsp.enable("gopls")
-- ^^^ Go ^^^ --

-- ▾▾▾ Commands ▾▾▾ --
vim.api.nvim_create_user_command("LspStart", function()
   vim.cmd.e()
end, { desc = "Starts LSP clients in the current buffer" })

vim.api.nvim_create_user_command("LspStop", function(opts)
   for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
      if opts.args == "" or opts.args == client.name then
         client:stop(true)
         vim.notify(client.name .. ": stopped")
      end
   end
end, {
   desc = "Stop all LSP clients or a specific client attached to the current buffer.",
   nargs = "?",
   complete = function(_, _, _)
      local clients = vim.lsp.get_clients({ bufnr = 0 })
      local client_names = {}
      for _, client in ipairs(clients) do
         table.insert(client_names, client.name)
      end
      return client_names
   end,
})

vim.api.nvim_create_user_command("LspRestart", function()
   local detach_clients = {}
   for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
      client:stop(true)
      if vim.tbl_count(client.attached_buffers) > 0 then
         detach_clients[client.name] = { client, vim.tbl_keys(client.attached_buffers) }
      end
   end
   local timer = vim.uv.new_timer()
   if not timer then
      return vim.notify("Servers are stopped but havent been restarted")
   end
   timer:start(
      100,
      50,
      vim.schedule_wrap(function()
         for name, client in pairs(detach_clients) do
            local client_id = vim.lsp.start(client[1].config, { attach = false })
            if client_id then
               for _, buf in ipairs(client[2]) do
                  vim.lsp.buf_attach_client(buf, client_id)
               end
               vim.notify(name .. ": restarted")
            end
            detach_clients[name] = nil
         end
         if next(detach_clients) == nil and not timer:is_closing() then
            timer:close()
         end
      end)
   )
end, {
   desc = "Restart all the language client(s) attached to the current buffer",
})

vim.api.nvim_create_user_command("LspLog", function()
   vim.cmd.vsplit(vim.lsp.log.get_filename())
end, {
   desc = "Get all the lsp logs",
})

vim.api.nvim_create_user_command("LspInfo", function()
   vim.cmd("silent checkhealth vim.lsp")
end, {
   desc = "Get all the information about all LSP attached",
})
-- ^^^ Commands ^^^ --

-- Diagnostics --

vim.diagnostic.config({
   virtual_text = true,
   virtual_lines = false,
   float = {
      source = "always",
      border = "rounded",
   },
   signs = true,
   underline = true,
   update_in_insert = false,
   severity_sort = true,
})

--- Virtual hover ---

vim.lsp.handlers["textDocument/hover"] = function(err, result, ctx, config)
   return vim.lsp.handlers.hover(err, result, ctx, vim.tbl_extend("force", config or {}, {
      border = "rounded", -- "none", "single", "double", "rounded", "solid", "shadow"
   }))
end

vim.lsp.enable({
   "clangd",
   "rust_analyzer",
   "htmlls",
   "cmake",
   "bashls",
   "jsonls",
   "lua_ls",
   "basedpyright",
   "ruff",
   "markdown_oxide",
   "gopls"
})
