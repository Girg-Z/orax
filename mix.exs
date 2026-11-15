defmodule Orax.MixProject do
  use Mix.Project

  def project do
    [app: :orax,
     version: "0.5.12",
     elixir: "~> 1.18",
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
    "Erlang driver and Ecto adapter for Oracle"
  end

  defp package do
    [files: ["src","include","lib","mix.exs"],
    maintainers: ["Giorgio Zanchetti"],
    licenses: ["MIT"],
    links: %{"Github" => "https://github.com/Girg-Z/orax"}]
  end
end
