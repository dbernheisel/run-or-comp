defmodule Runorcomp.TracerTest do
  use ExUnit.Case

  setup do
    Runorcomp.Tracer.start()
    existing = Code.get_compiler_option(:tracers)
    Code.put_compiler_option(:tracers, [Runorcomp.Tracer | existing])
    Code.put_compiler_option(:ignore_module_conflict, true)

    on_exit(fn ->
      Code.put_compiler_option(:tracers, existing)
      Code.put_compiler_option(:ignore_module_conflict, false)
      Runorcomp.Tracer.stop()
    end)

    :ok
  end

  defp compile(source) do
    Code.compile_string(source)
    Runorcomp.Tracer.entries()
  end

  defp entry_details(entries) do
    entries
    |> Enum.map(fn {_file, e} -> {e.line, e.detail.kind, e.detail.module, e.detail.name} end)
    |> Enum.sort()
  end

  describe "module-level function calls" do
    test "records function calls at module level as compile-time" do
      entries =
        compile("""
        defmodule TestModLevel do
          @version Mix.env()
        end
        """)

      details = entry_details(entries)
      assert Enum.any?(details, fn {_, _kind, mod, name} -> mod == Mix and name == :env end)
    end

    test "ignores function calls inside def bodies" do
      entries =
        compile("""
        defmodule TestFnBody do
          def hello do
            Mix.env()
          end
        end
        """)

      details = entry_details(entries)
      refute Enum.any?(details, fn {_, _, mod, _} -> mod == Mix end)
    end
  end

  describe "stdlib filtering" do
    test "skips Kernel module calls" do
      entries =
        compile("""
        defmodule TestKernel do
          @val if true, do: 1, else: 2
        end
        """)

      details = entry_details(entries)
      refute Enum.any?(details, fn {_, _, mod, _} -> mod == Kernel end)
    end

    test "skips Elixir stdlib modules like String, Enum, Map" do
      entries =
        compile("""
        defmodule TestStdlib do
          @trimmed String.trim("hello ")
          @keys Map.keys(%{a: 1})
        end
        """)

      details = entry_details(entries)
      refute Enum.any?(details, fn {_, _, mod, _} -> mod == String end)
      refute Enum.any?(details, fn {_, _, mod, _} -> mod == Map end)
    end

    test "keeps Mix and Application calls" do
      entries =
        compile("""
        defmodule TestKeepMix do
          @env Mix.env()
        end
        """)

      details = entry_details(entries)
      assert Enum.any?(details, fn {_, _, mod, _} -> mod == Mix end)
    end
  end

  describe "macro filtering" do
    test "skips use/defmodule macros" do
      entries =
        compile("""
        defmodule TestUseMacro do
          use GenServer
        end
        """)

      details = entry_details(entries)
      refute Enum.any?(details, fn {_, _, _, name} -> name == :__using__ end)
      refute Enum.any?(details, fn {_, _, _, name} -> name == :defmodule end)
    end

    test "skips alias/import/require" do
      entries =
        compile("""
        defmodule TestDirectives do
          alias Map, as: M
          import Enum, only: [map: 2]
          require Logger
        end
        """)

      details = entry_details(entries)
      refute Enum.any?(details, fn {_, kind, _, _} -> kind in [:alias, :import, :require] end)
    end

    test "records non-stdlib macros" do
      compile("""
      defmodule TestMacroProvider do
        defmacro my_dsl(name) do
          quote do: @dsl_entries unquote(name)
        end
      end
      """)

      Runorcomp.Tracer.start()

      entries =
        compile("""
        defmodule TestCustomMacro do
          require TestMacroProvider
          TestMacroProvider.my_dsl(:hello)
        end
        """)

      details = entry_details(entries)

      assert Enum.any?(details, fn {_, _, mod, name} ->
               mod == TestMacroProvider and name == :my_dsl
             end)
    end
  end

  describe "compile_env" do
    test "records Application.compile_env calls" do
      entries =
        compile("""
        defmodule TestCompileEnv do
          @val Application.compile_env(:my_app, :key, :default)
        end
        """)

      details = entry_details(entries)
      assert Enum.any?(details, fn {_, kind, _, _} -> kind == :compile_env end)
    end
  end

  describe "__before_compile__ tracking" do
    test "records __before_compile__ for callback detection" do
      compile("""
      defmodule TestBeforeCompileProvider do
        defmacro __using__(_opts) do
          quote do
            @before_compile TestBeforeCompileProvider
          end
        end

        defmacro __before_compile__(_env) do
          quote do: :ok
        end
      end
      """)

      Runorcomp.Tracer.start()

      entries =
        compile("""
        defmodule TestBeforeCompileUser do
          use TestBeforeCompileProvider
        end
        """)

      details = entry_details(entries)

      assert Enum.any?(details, fn {_, _, mod, name} ->
               mod == TestBeforeCompileProvider and name == :__before_compile__
             end)
    end
  end

  describe "flush/0" do
    test "returns 0 when no entries exist" do
      Runorcomp.Tracer.start()
      assert Runorcomp.Tracer.flush() == 0
    end
  end

  describe "traced_files/0" do
    test "returns MapSet of traced files" do
      compile("""
      defmodule TestTracedFiles do
        @env Mix.env()
      end
      """)

      traced = Runorcomp.Tracer.traced_files()
      assert is_struct(traced, MapSet)
      assert MapSet.size(traced) > 0
    end

    test "returns empty MapSet when no entries" do
      Runorcomp.Tracer.start()
      assert Runorcomp.Tracer.traced_files() == MapSet.new()
    end
  end
end
