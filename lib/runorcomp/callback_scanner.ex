defmodule Runorcomp.CallbackScanner do
  @moduledoc """
  Scans dependency source files for `__before_compile__` macros to discover
  which callbacks they invoke at compile time via dynamic dispatch.

  For example, `Plug.Builder` defines `__before_compile__/1` which eventually
  calls `plug.init(opts)` — meaning any module using `Plug.Builder` has its
  `init/1` invoked at compile time.
  """

  # Internal/meta functions that show up as dynamic dispatch but aren't callbacks
  @skip_functions [
    :__info__,
    :__struct__,
    :module_info,
    :unquote,
    :to_string
  ]

  @doc """
  Scans all deps for compile-time callback patterns.

  Returns a map of `module => [callback_names]`, e.g.:

      %{
        Plug.Builder => [:init],
        Phoenix.Router => [:init, :call]
      }
  """
  def scan(deps_path \\ "deps") do
    deps_path
    |> Path.join("*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn file, acc ->
      case scan_file(file) do
        {mod, callbacks} when is_atom(mod) and callbacks != [] ->
          Map.put(acc, mod, callbacks)

        _ ->
          acc
      end
    end)
  end

  @doc false
  def scan_file(path) do
    source = File.read!(path)

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        if defines_before_compile?(ast) do
          mod = extract_module_name(ast)
          callbacks = find_compile_time_callbacks(ast)
          {mod, callbacks}
        else
          {nil, []}
        end

      _ ->
        {nil, []}
    end
  rescue
    _ -> {nil, []}
  end

  defp defines_before_compile?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:defmacro, _, [{:__before_compile__, _, _} | _]} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp extract_module_name(ast) do
    {_, mod} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, nil ->
          {node, Module.concat(parts)}

        node, acc ->
          {node, acc}
      end)

    mod
  end

  # Find callbacks by tracing the call chain from __before_compile__.
  # 1. Find functions called directly in the __before_compile__ macro body
  # 2. Transitively follow local calls to find all reachable functions
  # 3. Collect dynamic dispatch (var.func(args)) from all reachable functions
  defp find_compile_time_callbacks(ast) do
    # Build a map of function_name => AST body for all def/defp in the module
    function_bodies = collect_function_bodies(ast)

    # Find local function calls from __before_compile__ macro body
    before_compile_body = extract_before_compile_body(ast)
    direct_calls = find_local_calls(before_compile_body)

    # Transitively collect all reachable function names
    reachable = expand_reachable(MapSet.new(direct_calls), function_bodies)

    # Find dynamic dispatch in reachable functions
    reachable
    |> Enum.flat_map(fn func ->
      function_bodies
      |> Map.get(func, [])
      |> Enum.flat_map(&find_dynamic_dispatch_calls/1)
    end)
    |> Kernel.++(find_dynamic_dispatch_calls(before_compile_body))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @skip_functions))
    |> Enum.reject(&(Atom.to_string(&1) |> String.starts_with?("__")))
  end

  defp expand_reachable(current, function_bodies) do
    new =
      Enum.reduce(current, current, fn func, acc ->
        function_bodies
        |> Map.get(func, [])
        |> Enum.reduce(acc, fn body, inner_acc ->
          MapSet.union(inner_acc, MapSet.new(find_local_calls(body)))
        end)
      end)

    if MapSet.size(new) == MapSet.size(current) do
      current
    else
      expand_reachable(new, function_bodies)
    end
  end

  defp extract_before_compile_body(ast) do
    {_, body} =
      Macro.prewalk(ast, nil, fn
        {:defmacro, _, [{:__before_compile__, _, _} | _]} = node, nil -> {node, node}
        node, acc -> {node, acc}
      end)

    body
  end

  defp collect_function_bodies(ast) do
    {_, bodies} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [{name, _, _} | _]} = node, acc
        when kind in [:def, :defp] and is_atom(name) ->
          {node, Map.update(acc, name, [node], &[node | &1])}

        node, acc ->
          {node, acc}
      end)

    bodies
  end

  # Find local function calls in an AST — both bare calls (name(args))
  # and qualified self-calls (Module.name(args)).
  # Skips inside quote blocks to avoid finding AST node names.
  defp find_local_calls(nil), do: []

  defp find_local_calls(ast) do
    {_, calls} = walk_for_calls(ast, [])
    Enum.uniq(calls)
  end

  defp walk_for_calls({:quote, _, _}, acc), do: {nil, acc}

  defp walk_for_calls({{:., _, [_mod, name]}, _, args} = node, acc)
       when is_atom(name) and is_list(args) do
    # Qualified call: Mod.func(args) — record func name, then walk args
    {_, acc} = walk_for_calls_list(args, [name | acc])
    {node, acc}
  end

  defp walk_for_calls({name, _, args} = node, acc)
       when is_atom(name) and is_list(args) and
              name not in [:def, :defp, :defmacro, :defmacrop, :quote, :unquote, :fn, :__block__] do
    {_, acc} = walk_for_calls_list(args, [name | acc])
    {node, acc}
  end

  defp walk_for_calls({left, right}, acc) do
    {_, acc} = walk_for_calls(left, acc)
    walk_for_calls(right, acc)
  end

  defp walk_for_calls(list, acc) when is_list(list) do
    walk_for_calls_list(list, acc)
  end

  defp walk_for_calls({_, _, children} = node, acc) when is_list(children) do
    {_, acc} = walk_for_calls_list(children, acc)
    {node, acc}
  end

  defp walk_for_calls(node, acc), do: {node, acc}

  defp walk_for_calls_list(list, acc) do
    Enum.reduce(list, {nil, acc}, fn item, {_, a} -> walk_for_calls(item, a) end)
  end

  # Find dynamic dispatch: var.func(args) where args is non-empty
  defp find_dynamic_dispatch_calls(nil), do: []

  defp find_dynamic_dispatch_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{var, _, ctx}, func]}, _, args} = node, acc
        when is_atom(var) and is_atom(ctx) and is_atom(func) and
               is_list(args) and length(args) > 0 and
               var not in [:__MODULE__, :__ENV__, :__CALLER__, :__STACKTRACE__] ->
          {node, [func | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(calls)
  end
end
