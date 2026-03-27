# RunOrComp

Elixir compile-time detection via compiler tracing. Produces a JSON database
that editor plugins can use to highlight code that runs at compile time vs runtime.

Includes a Neovim plugin that highlights compile-time lines with a subtle
background tint and virtual text labels.

## How it works

RunOrComp uses Elixir's [compilation tracer](https://hexdocs.pm/elixir/Code.html#module-compilation-tracers)
to observe which code constructs execute at compile time:

- **Macro calls** from non-stdlib dependencies (e.g., `Plug.Builder.plug/1`)
- **Module-level function calls** (e.g., `Mix.env/0`, `Application.compile_env/3`)
- **Compile-time callbacks** — dynamically discovered by scanning dependency
  source for `__before_compile__` macros and the callbacks they invoke
  (e.g., `Plug.Builder` calls `init/1` at compile time)

Standard library modules, Kernel constructs, and language plumbing are filtered
out so only meaningful compile-time indicators remain.

## Setup

Add `runorcomp` to your project's dependencies:

```elixir
defp deps do
  [
    {:runorcomp, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

Then configure the tracer and compiler in your project:

```elixir
def project do
  [
    compilers: Mix.compilers() ++ [:runorcomp],
    elixirc_options: [tracers: [Runorcomp.Tracer]],
    # ...
  ]
end
```

The tracer runs during `mix compile` and the compiler writes the database to
`_build/{env}/runorcomp.json` after each compilation pass. Incremental
compilation is supported — only recompiled files are re-traced, and existing
data for unchanged files is preserved.

Note: `.exs` files (like `mix.exs` or test support files) are not traced —
only `.ex` files compiled by `mix compile` are included.

## Neovim plugin

The included Neovim plugin reads the JSON database and highlights compile-time
lines with a subtle background tint and optional virtual text labels.

### Installation (lazy.nvim)

```lua
{
  "dbernheisel/runorcomp",
  ft = "elixir",
  config = function()
    vim.api.nvim_set_hl(0, "RunorcompCompileTime", { bg = "#1a1a2e" })
    vim.api.nvim_set_hl(0, "RunorcompLabel", { fg = "#6e6ea8", italic = true })
    require("runorcomp").setup()
  end,
}
```

### Commands

- `:RunorcompRefresh` — re-read the database and update highlights
- `:RunorcompClear` — remove all highlights
- `:RunorcompToggleLabels` — toggle virtual text labels on/off

### Options

```lua
require("runorcomp").setup({
  virtual_text = true, -- show "← target" labels (default: true)
})
```

### Highlight groups

| Group | Default | Purpose |
|-------|---------|---------|
| `RunorcompCompileTime` | links to `CursorLine` | Background tint on compile-time lines |
| `RunorcompLabel` | links to `Comment` | Virtual text label color |

Compile-time callbacks (like `init/1` called by `Plug.Builder`) highlight the
entire function body, not just the `def` line.
