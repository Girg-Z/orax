defmodule Orax.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Girg-Z/orax"

  def project do
    [
      app: :orax,
      version: @version,
      elixir: "~> 1.18",
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :public_key]
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Native Erlang driver and Ecto adapter for Oracle Database 19c and 26ai"
  end

  defp package do
    [
      files: ["src", "include", "lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"],
      maintainers: ["Giorgio Zanchetti"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
