defmodule Ordoq.MixProject do
  @moduledoc false
  use Mix.Project

  @version "1.0.1"
  @source_url "https://github.com/joetjen/ordoq"

  @spec project() :: keyword()
  def project do
    [
      app: :ordoq,
      version: @version,
      elixir: "~> 1.19",
      name: "Ordoq",
      description: "Bounded local in-memory priority queue for supervised asynchronous Elixir callbacks",
      source_url: @source_url,
      homepage_url: "https://joetjen.github.io/ordoq",
      docs: docs(),
      dialyzer: dialyzer(),
      aliases: aliases(),
      package: package(),
      test_paths: ["test/ordoq"],
      deps: deps()
    ]
  end

  @spec application() :: keyword()
  def application, do: [mod: {Ordoq.Application, []}]

  @spec cli() :: keyword()
  def cli do
    [
      preferred_envs: [
        credo: :dev,
        dialyzer: :dev,
        docs: :docs,
        precommit: :dev,
        test: :test
      ]
    ]
  end

  @spec dialyzer() :: keyword()
  def dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: "_build/plts",
      plt_file: {:no_warn, "_build/plts/dialyzer.plt"}
    ]
  end

  @spec docs() :: keyword()
  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      homepage_url: "https://joetjen.github.io/ordoq",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        Core: [Ordoq, Ordoq.Queue],
        Support: [Ordoq.Application, Ordoq.Error, Ordoq.Telemetry]
      ]
    ]
  end

  @spec package() :: keyword()
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://joetjen.github.io/ordoq"
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  @spec aliases() :: keyword()
  defp aliases do
    [
      build: ["compile --force --warnings-as-errors"],
      precommit: [
        "build",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "cmd sh -c 'MIX_ENV=test mix test'"
      ]
    ]
  end

  @spec deps() :: [Mix.Project.dependency()]
  defp deps do
    [
      # development and test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:docs], runtime: false},
      {:stream_data, "~> 1.2", only: [:dev, :test]},

      # runtime dependencies
      {:telemetry, "~> 1.3"}
    ]
  end
end
