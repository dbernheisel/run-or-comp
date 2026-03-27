-- runorcomp.nvim — compile-time vs runtime highlighting for Elixir
--
-- Reads .runorcomp.json from the project root and highlights
-- compile-time lines with a subtle background tint, plus optional
-- virtual text showing what runs at compile time.
--
-- Usage (lazy.nvim):
--   { 'dbernheisel/runorcomp', config = true }
--
-- Or source directly:
--   require("runorcomp").setup()

local M = {}

local ns = vim.api.nvim_create_namespace("runorcomp")

-- Cache: project_root -> { entries = {}, mtime = number }
local cache = {}

--- Find the project root by walking up from the buffer's directory
--- looking for .runorcomp.json or mix.exs
local function find_project_root(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then
    return nil
  end

  local dir = vim.fn.fnamemodify(bufname, ":h")
  local prev = nil
  while dir ~= prev do
    if vim.uv.fs_stat(dir .. "/.runorcomp.json") then
      return dir
    end
    if vim.uv.fs_stat(dir .. "/mix.exs") then
      return dir
    end
    prev = dir
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  return nil
end

--- Load and cache runorcomp.json from a project's _build directory
local function load_database(project_root)
  -- Prefer test (includes test/support), then dev, then prod
  local path
  for _, env in ipairs({ "test", "dev", "prod" }) do
    local candidate = project_root .. "/_build/" .. env .. "/runorcomp.json"
    if vim.uv.fs_stat(candidate) then
      path = candidate
      break
    end
  end
  if not path then
    return nil
  end

  local mtime = vim.uv.fs_stat(path).mtime.sec
  local cached = cache[project_root]
  if cached and cached.mtime == mtime then
    return cached.entries
  end

  local fd = io.open(path, "r")
  if not fd then
    return nil
  end

  local content = fd:read("*a")
  fd:close()

  local ok, entries = pcall(vim.json.decode, content)
  if not ok then
    vim.notify("[runorcomp] Failed to parse " .. path, vim.log.levels.WARN)
    return nil
  end

  cache[project_root] = { entries = entries, mtime = mtime }
  return entries
end

--- Collect compile-time lines from database entries, grouped by line.
--- Everything in the database is compile-time (runtime is omitted).
local function compile_time_lines(entries, relative_path)
  local file_entries = entries[relative_path]
  if not file_entries then
    return {}
  end

  local by_line = {}
  for _, entry in ipairs(file_entries) do
    local line = entry.line
    if not by_line[line] then
      by_line[line] = {}
    end
    table.insert(by_line[line], entry)
  end

  return by_line
end

--- Use tree-sitter to find the end line of a function definition.
--- lnum and col are 0-indexed.
local function find_function_end(bufnr, lnum, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "elixir")
  if not ok or not parser then
    return lnum
  end

  local tree = parser:parse()[1]
  if not tree then
    return lnum
  end

  local root = tree:root()
  local node = root:named_descendant_for_range(lnum, col, lnum, col)

  while node do
    if node:type() == "call" then
      local first_child = node:named_child(0)
      if first_child and first_child:type() == "identifier" then
        local name = vim.treesitter.get_node_text(first_child, bufnr)
        if name == "def" or name == "defp" or name == "defmacro" or name == "defmacrop" then
          local _, _, end_row, _ = node:range()
          return end_row
        end
      end
    end
    node = node:parent()
  end

  return lnum
end

--- Apply extmark highlights to a buffer
local function apply_highlights(bufnr, opts)
  -- Clear previous marks
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local ft = vim.bo[bufnr].filetype
  if ft ~= "elixir" then
    return
  end

  local project_root = find_project_root(bufnr)
  if not project_root then
    return
  end

  local entries = load_database(project_root)
  if not entries then
    return
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = bufname:sub(#project_root + 2)

  local by_line = compile_time_lines(entries, relative_path)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for line, line_entries in pairs(by_line) do
    local lnum = line - 1 -- 0-indexed
    if lnum >= 0 and lnum < line_count then
      -- Check if any entry is a compile_callback — if so, highlight the whole function
      local end_lnum = lnum
      for _, e in ipairs(line_entries) do
        if e.kind == "compile_callback" then
          local col = (e.column or 1) - 1 -- convert 1-indexed to 0-indexed
          end_lnum = find_function_end(bufnr, lnum, col)
          break
        end
      end

      -- Build virtual text label
      local virt_text_opts = nil
      if opts.virtual_text then
        local targets = {}
        local seen = {}
        for _, e in ipairs(line_entries) do
          if e.target and not seen[e.target] then
            seen[e.target] = true
            table.insert(targets, e.target)
          end
        end

        if #targets > 0 then
          local label = table.concat(targets, ", ")
          virt_text_opts = { { " " .. label, "RunorcompLabel" } }
        end
      end

      -- For multi-line ranges (compile_callback), highlight each line
      for l = lnum, end_lnum do
        local mark_opts = {
          line_hl_group = "RunorcompCompileTime",
          priority = 10,
        }
        -- Only add virtual text on the first line
        if l == lnum and virt_text_opts then
          mark_opts.virt_text = virt_text_opts
          mark_opts.virt_text_pos = "eol"
        end
        vim.api.nvim_buf_set_extmark(bufnr, ns, l, 0, mark_opts)
      end
    end
  end
end

--- Refresh highlights for all Elixir buffers
function M.refresh()
  cache = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      apply_highlights(bufnr, M._opts)
    end
  end
end

--- Clear all runorcomp highlights
function M.clear()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  cache = {}
end

local function setup_highlight_groups()
  -- Subtle background tint for compile-time lines
  -- Links to CursorLine by default — most colorschemes make this a gentle highlight
  vim.api.nvim_set_hl(0, "RunorcompCompileTime", { default = true, link = "CursorLine" })
  -- Dimmed label for virtual text
  vim.api.nvim_set_hl(0, "RunorcompLabel", { default = true, link = "Comment" })
end

function M.setup(opts)
  opts = vim.tbl_deep_extend("force", {
    virtual_text = true,
  }, opts or {})

  M._opts = opts

  setup_highlight_groups()

  local group = vim.api.nvim_create_augroup("runorcomp", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = "*.ex",
    callback = function(ev)
      apply_highlights(ev.buf, opts)
    end,
  })

  -- Re-apply when the database file changes
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*/runorcomp.json",
    callback = function()
      M.refresh()
    end,
  })

  -- Re-apply when colorscheme changes so highlight groups persist
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = setup_highlight_groups,
  })

  -- User commands
  vim.api.nvim_create_user_command("RunorcompRefresh", function()
    M.refresh()
    vim.notify("[runorcomp] Refreshed", vim.log.levels.INFO)
  end, { desc = "Refresh runorcomp highlights" })

  vim.api.nvim_create_user_command("RunorcompClear", function()
    M.clear()
  end, { desc = "Clear runorcomp highlights" })

  vim.api.nvim_create_user_command("RunorcompToggleLabels", function()
    opts.virtual_text = not opts.virtual_text
    M.refresh()
    local state = opts.virtual_text and "on" or "off"
    vim.notify("[runorcomp] Labels " .. state, vim.log.levels.INFO)
  end, { desc = "Toggle runorcomp virtual text labels" })

  -- Apply to any already-open Elixir buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name:match("%.ex$") then
        apply_highlights(bufnr, opts)
      end
    end
  end
end

return M
