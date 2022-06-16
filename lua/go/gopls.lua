local utils = require("go.utils")
local log = utils.log
local vfn = vim.fn

local M = {}
local cmds = {}
-- https://go.googlesource.com/tools/+/refs/heads/master/gopls/doc/commands.md
-- "executeCommandProvider":{"commands":["gopls.add_dependency","gopls.add_import","gopls.apply_fix","gopls.check_upgrades","gopls.gc_details","gopls.generate","gopls.generate_gopls_mod","gopls.go_get_package","gopls.list_known_packages","gopls.regenerate_cgo","gopls.remove_dependency","gopls.run_tests","gopls.start_debugging","gopls.test","gopls.tidy","gopls.toggle_gc_details","gopls.update_go_sum","gopls.upgrade_dependency","gopls.vendor","gopls.workspace_metadata"]}

local gopls_cmds = {
  "gopls.add_dependency",
  "gopls.add_import",
  "gopls.apply_fix",
  "gopls.check_upgrades",
  "gopls.gc_details",
  "gopls.generate",
  "gopls.generate_gopls_mod",
  "gopls.go_get_package",
  "gopls.list_known_packages",
  "gopls.list_imports",
  "gopls.regenerate_cgo",
  "gopls.remove_dependency",
  "gopls.run_tests",
  "gopls.start_debugging",
  "gopls.test",
  "gopls.tidy",
  "gopls.toggle_gc_details",
  "gopls.update_go_sum",
  "gopls.upgrade_dependency",
  "gopls.vendor",
  "gopls.workspace_metadata",
}

local gopls_with_result = {
  "gopls.gc_details",
  "gopls.list_known_packages",
  "gopls.list_imports",
}

local function check_for_error(msg)
  if msg ~= nil and type(msg[1]) == "table" then
    for k, v in pairs(msg[1]) do
      if k == "error" then
        log("LSP", v.message)
        break
      end
    end
  end
end

for _, value in ipairs(gopls_cmds) do
  local fname = string.sub(value, #"gopls." + 1)
  cmds[fname] = function(arg)
    log(fname)
    local b = vim.api.nvim_get_current_buf()
    local uri = vim.uri_from_bufnr(b)
    local arguments = { { URI = uri } }

    local ft = vim.bo.filetype
    if ft == "gomod" or ft == "gosum" then
      arguments = { { URIs = { uri } } }
    end
    arguments = { vim.tbl_extend("keep", arguments[1], arg or {}) }

    if vim.tbl_contains(gopls_with_result, value) then
      local resp = vim.lsp.buf_request_sync(b, "workspace/executeCommand", {
        command = value,
        arguments = arguments,
      }, 2000)
      check_for_error(resp)
      log(resp)

      return resp
    end

    vim.schedule(function()
      local resp = vim.lsp.buf.execute_command({
        command = value,
        arguments = arguments,
      })
      check_for_error(resp)
      log(resp)
    end)
  end
end

M.import = function(path)
  cmds.add_import({
    ImportPath = path,
  })
end

M.list_imports = function(path)
  path = path or vim.fn.expand("%:p")
  local resp = cmds.list_imports({
    URI = path,
  })
  result = {}
  for _, v in pairs(resp) do
    if v.result then
      for k, val in pairs(v.result) do
        result[k] = {}
        for _, imp in ipairs(val) do
          if imp.Name and imp.Name ~= "" then
            table.insert(result[k], imp.Name .. ":" .. imp.Path)
          else
            table.insert(result[k], imp.Path)
          end
        end
      end
    end
  end
  return result, resp
end

M.list_pkgs = function()
  local resp = cmds.list_known_packages() or {}

  local pkgs = {}
  for _, response in pairs(resp) do
    if response.result ~= nil then
      pkgs = response.result.Packages
      break
    end
  end
  return pkgs
end

M.tidy = function()
  cmds.tidy()
end

-- check_for_upgrades({Modules = {'package'}})
function M.version()
  local cache_dir = vfn.stdpath("cache")
  local path = string.format("%s%sversion.txt", cache_dir, utils.sep())
  local cfg = _GO_NVIM_CFG or {}
  local gopls = cfg.gopls_cmd or { "gopls" }

  if vfn.executable(gopls[1]) == 0 then
    vim.notify("gopls not found", vim.log.levels.WARN)
    return
  end
  vfn.jobstart({ gopls[1], "version" }, {
    on_stdout = function(_, data, _)
      local msg = ""
      if type(data) == "table" and #data > 0 then
        data = table.concat(data, " ")
      end
      if #data > 1 then
        msg = msg .. data
      end
      log(msg)

      local version = string.match(msg, "%s+v([%d%.]+)%s+")
      if version == nil then
        log(version, msg)
        return
      end

      local f = io.open(path, "w+")
      if f == nil then
        return
      end
      f:write(version)
      f:close()
      log(version)
    end,
  })

  local f = io.open(path, "r")
  if f == nil then
    local version_cmd = gopls[1] .. " version"
    return vfn.system(version_cmd):match("%s+v([%d%.]+)%s+")
  end
  local version = f:read("*l")
  f:close()
  log(version)
  return version
end

local setups = {
  capabilities = {
    textDocument = {
      completion = {
        completionItem = {
          commitCharactersSupport = true,
          deprecatedSupport = true,
          documentationFormat = { "markdown", "plaintext" },
          preselectSupport = true,
          insertReplaceSupport = true,
          labelDetailsSupport = true,
          snippetSupport = true,
          resolveSupport = {
            properties = {
              "documentation",
              "details",
              "additionalTextEdits",
            },
          },
        },
        contextSupport = true,
        dynamicRegistration = true,
      },
    },
  },
  filetypes = { "go", "gomod", "gosum", "gotmpl", "gohtmltmpl", "gotexttmpl" },
  message_level = vim.lsp.protocol.MessageType.Error,
  cmd = {
    "gopls", -- share the gopls instance if there is one already
    "-remote.debug=:0",
  },
  root_dir = function(fname)
    local has_lsp, lspconfig = pcall(require, "lspconfig")
    if has_lsp then
      local util = lspconfig.util
      return util.root_pattern("go.mod", ".git")(fname) or util.path.dirname(fname)
    end
  end,
  flags = { allow_incremental_sync = true, debounce_text_changes = 500 },
  settings = {
    gopls = {
      -- more settings: https://github.com/golang/tools/blob/master/gopls/doc/settings.md
      -- flags = {allow_incremental_sync = true, debounce_text_changes = 500},
      -- not supported
      analyses = { unusedparams = true, unreachable = false },
      codelenses = {
        generate = true, -- show the `go generate` lens.
        gc_details = true, --  // Show a code lens toggling the display of gc's choices.
        test = true,
        tidy = true,
      },
      usePlaceholders = true,
      completeUnimported = true,
      staticcheck = true,
      matcher = "Fuzzy",
      diagnosticsDelay = "500ms",
      experimentalWatchedFileDelay = "100ms",
      symbolMatcher = "fuzzy",
      ["local"] = "",
      gofumpt = false, -- true, -- turn on for new repos, gofmpt is good but also create code turmoils
      buildFlags = { "-tags", "integration" },
      -- buildFlags = {"-tags", "functional"}
    },
  },
}

M.setups = function()
  local v = M.version()
  if v == nil then
    return
  end
  if v > "0.7" then
    setups.settings = vim.tbl_deep_extend("force", setups.settings, {
      experimentalPostfixCompletions = true,
      experimentalUseInvalidMetadata = true,
      hoverKind = "Structured",
    })
  end
  return setups
end

return M
