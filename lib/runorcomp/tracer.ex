defmodule Runorcomp.Tracer do
  @moduledoc """
  Compiler tracer that records which code constructs are compile-time vs runtime.

  All macro events are compile-time by definition. Function events are compile-time
  only when `env.function` is nil (module-level code), otherwise they're runtime.

  ## Usage as project tracer

  Add to your project's `mix.exs`:

      def project do
        [
          compilers: Mix.compilers() ++ [:runorcomp],
          elixirc_options: [tracers: [Runorcomp.Tracer]],
          ...
        ]
      end
  """

  require Logger

  @table __MODULE__
  @output_file "runorcomp.json"

  def start do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def stop do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  def entries do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table)
    else
      []
    end
  end

  @doc "Returns the set of files that were traced in this compilation pass."
  def traced_files do
    if :ets.whereis(@table) != :undefined do
      @table
      |> :ets.tab2list()
      |> Enum.reduce(MapSet.new(), fn {file, _}, acc -> MapSet.put(acc, file) end)
    else
      MapSet.new()
    end
  end

  # Build a set of all Elixir stdlib and OTP modules at compile time.
  # These are implementation details when called at module level, not
  # meaningful compile-time indicators.
  @stdlib_modules for(
                    app <- [:elixir, :logger, :eex, :ex_unit, :iex],
                    mod <- Application.spec(app, :modules) || [],
                    mod not in [Mix, Application],
                    do: mod
                  )
                  |> MapSet.new()

  # Erlang/OTP modules and compiler internals to skip
  @skip_erlang_modules MapSet.new([
                         :elixir_utils,
                         :elixir_def,
                         :elixir_module,
                         :elixir_bootstrap,
                         :erlang,
                         :timer
                       ])

  defp skip_module?(module) when is_atom(module) do
    MapSet.member?(@skip_erlang_modules, module) or MapSet.member?(@stdlib_modules, module)
  end

  # Macro events — always compile-time
  # Skip __using__ (just `use Module`) and defmodule — obvious from source.
  def trace({:remote_macro, _meta, _module, :__using__, _arity}, _env), do: :ok
  def trace({:imported_macro, _meta, _module, :defmodule, _arity}, _env), do: :ok

  # Always record __before_compile__ (needed for callback detection),
  # even though it gets filtered from JSON output.
  def trace({:remote_macro, meta, module, :__before_compile__ = name, arity}, env) do
    record(env, meta, {:remote_macro, module, name, arity})
  end

  def trace({:remote_macro, meta, module, name, arity}, env) do
    unless skip_module?(module), do: record(env, meta, {:remote_macro, module, name, arity})
    :ok
  end

  def trace({:local_macro, meta, name, arity}, env) do
    record(env, meta, {:local_macro, env.module, name, arity})
  end

  def trace({:imported_macro, meta, module, name, arity}, env) do
    unless skip_module?(module), do: record(env, meta, {:imported_macro, module, name, arity})
    :ok
  end

  # Function events — only record if at module level (compile-time)
  def trace({:remote_function, meta, module, name, arity}, %{function: nil} = env) do
    unless skip_module?(module), do: record(env, meta, {:remote_function, module, name, arity})
    :ok
  end

  def trace({:local_function, meta, name, arity}, %{function: nil} = env) do
    record(env, meta, {:local_function, env.module, name, arity})
  end

  def trace({:imported_function, meta, module, name, arity}, %{function: nil} = env) do
    unless skip_module?(module), do: record(env, meta, {:imported_function, module, name, arity})
    :ok
  end

  def trace({:remote_function, _, _, _, _}, _env), do: :ok
  def trace({:local_function, _, _, _}, _env), do: :ok
  def trace({:imported_function, _, _, _, _}, _env), do: :ok

  # Structural compile-time events — skip alias/import/require,
  # they're ubiquitous and not useful to highlight
  def trace({:alias, _, _, _, _}, _env), do: :ok
  def trace({:import, _, _, _}, _env), do: :ok
  def trace({:require, _, _, _}, _env), do: :ok

  def trace({:struct_expansion, _, _, _}, _env), do: :ok

  def trace({:compile_env, app, path, _return}, env) do
    record(env, [], {:compile_env, app, path})
  end

  # Catch-all for future events
  def trace(_event, _env), do: :ok

  # Use a persistent_term to track whether the table owner process is alive.
  # This avoids spawning orphan processes on repeated ensure_table calls.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      pid =
        spawn(fn ->
          :ets.new(@table, [:named_table, :public, :bag])
          ref = make_ref()
          receive do: (^ref -> :ok)
        end)

      # Store owner so we can check liveness
      :persistent_term.put({__MODULE__, :owner}, pid)
      wait_for_table(50)
    else
      # Table exists — verify owner is alive
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        pid when is_pid(pid) ->
          unless Process.alive?(pid) do
            Logger.warning("[runorcomp] ETS table owner died unexpectedly")
          end

        _ ->
          :ok
      end
    end
  catch
    _, _ -> :ok
  end

  defp wait_for_table(0) do
    Logger.warning("[runorcomp] Timed out waiting for ETS table creation")
  end

  defp wait_for_table(attempts) do
    if :ets.whereis(@table) == :undefined do
      Process.sleep(1)
      wait_for_table(attempts - 1)
    end
  end

  defp record(env, meta, detail) do
    ensure_table()

    line = meta[:line] || env.line
    column = meta[:column]

    entry = %{
      file: env.file,
      line: line,
      column: column,
      module: env.module,
      detail: format_detail(detail)
    }

    :ets.insert(@table, {env.file, entry})
    :ok
  catch
    :error, :badarg ->
      Logger.warning("[runorcomp] Failed to insert trace entry — ETS table unavailable")
      :ok
  end

  defp format_detail({kind, module, name, arity}) do
    %{kind: kind, module: module, name: name, arity: arity}
  end

  defp format_detail({:compile_env, app, path}) do
    %{kind: :compile_env, module: app, name: path, arity: nil}
  end

  @doc """
  Writes trace data to `_build/{env}/runorcomp.json`, merging with existing data
  for files that weren't recompiled this pass. Then cleans up ETS.

  Called by `Mix.Tasks.Compile.Runorcomp` after Elixir compilation finishes.
  """
  def flush do
    all_entries = entries()

    if all_entries != [] do
      project_root = File.cwd!()
      output_path = Path.join([Mix.Project.build_path(), @output_file])
      existing = load_existing(output_path)
      traced = traced_files() |> Enum.map(&Path.relative_to(&1, project_root)) |> MapSet.new()

      # Scan deps for compile-time callbacks (e.g., Plug.Builder calls init/1)
      callback_map = Runorcomp.CallbackScanner.scan()

      new_data =
        all_entries
        |> Enum.map(fn {_file, entry} -> entry end)
        |> Enum.group_by(& &1.file)
        |> Map.new(fn {file, file_entries} ->
          relative_path = Path.relative_to(file, project_root)

          # Find callback functions invoked at compile time in this file
          callback_entries = find_callback_entries(file, file_entries, callback_map)

          sorted =
            (file_entries ++ callback_entries)
            |> Enum.reject(&(&1.detail.name == :__before_compile__))
            |> Enum.sort_by(&{&1.line, &1.column || 0})
            |> Enum.uniq_by(&{&1.line, &1.column, &1.detail.kind})
            |> Enum.map(&format_entry/1)

          {relative_path, sorted}
        end)

      # Keep existing data for files not recompiled, replace for recompiled files
      merged =
        existing
        |> Enum.reject(fn {file, _} -> MapSet.member?(traced, file) end)
        |> Map.new()
        |> Map.merge(new_data)

      json = JSON.encode!(merged)
      File.write!(output_path, json)

      stop()
      map_size(merged)
    else
      0
    end
  end

  # Check if any __before_compile__ macros in this file come from modules
  # known to call specific callbacks. If so, find the `def callback` lines
  # in the source file and add synthetic entries.
  defp find_callback_entries(file, file_entries, callback_map) do
    # Which modules' __before_compile__ fired in this file?
    # Collect {callback_name, source_module} pairs
    callbacks =
      file_entries
      |> Enum.flat_map(fn entry ->
        case entry.detail do
          %{kind: :remote_macro, module: module, name: :__before_compile__} ->
            for cb <- Map.get(callback_map, module, []), do: {cb, module}

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    if callbacks == [] do
      []
    else
      find_def_lines(file, callbacks)
    end
  end

  # Parse the source file and find `def callback_name` lines
  defp find_def_lines(file, callbacks) do
    source = File.read!(file)
    callback_map = Map.new(callbacks)

    case Code.string_to_quoted(source, file: file, columns: true) do
      {:ok, ast} ->
        {_, found} =
          Macro.prewalk(ast, [], fn
            {:def, meta, [{name, _, _} | _]} = node, acc when is_atom(name) ->
              case Map.fetch(callback_map, name) do
                {:ok, source_module} ->
                  entry = %{
                    file: file,
                    line: meta[:line],
                    column: meta[:column],
                    module: nil,
                    detail: %{
                      kind: :compile_callback,
                      module: source_module,
                      name: name,
                      arity: nil
                    }
                  }

                  {node, [entry | acc]}

                :error ->
                  {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        found

      _ ->
        []
    end
  end

  defp format_entry(entry) do
    base = %{"line" => entry.line, "kind" => Atom.to_string(entry.detail.kind)}
    base = if entry.column, do: Map.put(base, "column", entry.column), else: base
    target = format_target(entry.detail)
    if target, do: Map.put(base, "target", target), else: base
  end

  defp format_target(%{kind: :compile_callback, module: mod, name: name}) do
    "compiled (#{inspect(mod)}.#{name})"
  end

  defp format_target(%{kind: :compile_env, module: app, name: path}),
    do: "#{app}.#{inspect(path)}"

  defp format_target(%{module: nil}), do: nil

  defp format_target(%{module: mod, name: name, arity: arity}),
    do: "compiled (#{inspect(mod)}.#{name}/#{arity})"

  defp load_existing(path) do
    case File.read(path) do
      {:ok, content} -> JSON.decode!(content)
      _ -> %{}
    end
  rescue
    e ->
      Logger.warning("[runorcomp] Failed to read #{path}: #{inspect(e)}")
      %{}
  end
end
