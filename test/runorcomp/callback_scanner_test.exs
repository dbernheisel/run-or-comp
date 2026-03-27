defmodule Runorcomp.CallbackScannerTest do
  use ExUnit.Case

  describe "scan_file/1" do
    test "detects init callback from __before_compile__ that calls it" do
      {mod, callbacks} =
        write_and_scan("""
        defmodule FakeBuilder do
          defmacro __before_compile__(env) do
            plugs = Module.get_attribute(env.module, :plugs)
            compile(plugs)
          end

          def compile(plugs) do
            for plug <- plugs do
              plug.init([])
            end
          end
        end
        """)

      assert mod == FakeBuilder
      assert :init in callbacks
    end

    test "ignores modules without __before_compile__" do
      assert {nil, []} =
               write_and_scan("""
               defmodule NormalModule do
                 def hello, do: :world
               end
               """)
    end

    test "filters dunder functions" do
      {_mod, callbacks} =
        write_and_scan("""
        defmodule DunderModule do
          defmacro __before_compile__(env) do
            setup(env.module)
          end

          def setup(mod) do
            mod.__info__(:functions)
            mod.__struct__()
            mod.init([])
          end
        end
        """)

      assert :init in callbacks
      refute :__info__ in callbacks
      refute :__struct__ in callbacks
    end

    test "only detects calls with arguments (not field access)" do
      {_mod, callbacks} =
        write_and_scan("""
        defmodule FieldAccess do
          defmacro __before_compile__(env) do
            setup(env.module)
          end

          def setup(mod) do
            name = mod.name
            mod.init(name)
          end
        end
        """)

      assert :init in callbacks
      refute :name in callbacks
    end

    test "limits search to functions reachable from __before_compile__" do
      {_mod, callbacks} =
        write_and_scan("""
        defmodule ReachabilityTest do
          defmacro __before_compile__(env) do
            compile(env.module)
          end

          def compile(mod) do
            mod.init([])
          end

          def unrelated(conn) do
            conn.send_resp(200, "ok")
          end
        end
        """)

      assert :init in callbacks
      refute :send_resp in callbacks
    end
  end

  describe "scan/1" do
    test "returns empty map for empty directory" do
      dir = Path.join(System.tmp_dir!(), "runorcomp_empty_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        assert %{} = Runorcomp.CallbackScanner.scan(dir)
      after
        File.rm_rf!(dir)
      end
    end
  end

  defp write_and_scan(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "runorcomp_test_#{:erlang.unique_integer([:positive])}.ex"
      )

    File.write!(path, source)

    try do
      Runorcomp.CallbackScanner.scan_file(path)
    after
      File.rm(path)
    end
  end
end
