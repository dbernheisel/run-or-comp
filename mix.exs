defmodule Runorcomp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dbernheisel/run-or-comp"

  def project do
    [
      app: :runorcomp,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "RunOrComp",
      description: "Compile-time vs runtime detection for Elixir via compiler tracing",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, warn_if_outdated: true, runtime: false},
      {:makeup_syntect, "~> 0.1", only: :dev}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
