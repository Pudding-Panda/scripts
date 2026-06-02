defmodule DevtimeServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:devtime_server, :port, 7879)

    children = [
      {Task.Supervisor, name: DevtimeServer.TaskSupervisor},
      DevtimeServer.ClientMap,
      DevtimeServer.DB,
      {Bandit, plug: DevtimeServer.Router, port: port, ip: {0, 0, 0, 0}}
    ]

    opts = [strategy: :one_for_one, name: DevtimeServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
