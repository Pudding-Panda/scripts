defmodule DevtimeServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :devtime_server,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {DevtimeServer.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.15"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.23"}
    ]
  end
end
