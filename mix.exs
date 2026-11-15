defmodule Orax.MixProject do
  use Mix.Project

  def project do
    [app: :orax,
     version: "0.1.0",
     elixir: "~> 1.18",
     test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
     description: description(),
     package: package(),
     deps: deps()]
  end

  def application do
    [
      extra_applications: [:crypto, :public_key]
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.14"}
    ]
  end

  defp description do
    "Native Erlang driver and Ecto adapter for Oracle Database 19c and 26ai"
  end

  defp package do
    [files: ["src", "include", "lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"],
    maintainers: ["Giorgio Zanchetti"],
    licenses: ["MIT"],
    links: %{"Github" => "https://github.com/Girg-Z/orax"}]
  end
end
