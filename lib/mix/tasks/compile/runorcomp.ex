defmodule Mix.Tasks.Compile.Runorcomp do
  @moduledoc """
  Flushes compile tracer data to `_build/{env}/runorcomp.json` after Elixir compilation.

  ## Setup

  Add both the tracer and compiler to your `mix.exs`:

      def project do
        [
          compilers: Mix.compilers() ++ [:runorcomp],
          elixirc_options: [tracers: [Runorcomp.Tracer]],
          ...
        ]
      end
  """

  use Mix.Task.Compiler

  @impl true
  def run(_argv) do
    case Runorcomp.Tracer.flush() do
      0 ->
        {:noop, []}

      count ->
        Mix.shell().info("[runorcomp] Updated #{count} files")
        {:ok, []}
    end
  end
end
