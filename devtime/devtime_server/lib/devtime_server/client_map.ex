defmodule DevtimeServer.ClientMap do
  use GenServer

  @default_path "/app/config/client_map.json"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def resolve(cwd) do
    GenServer.call(__MODULE__, {:resolve, cwd})
  end

  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @impl true
  def init(_opts) do
    map_path = Application.get_env(:devtime_server, :client_map_path, @default_path)
    {:ok, %{path: map_path, map: load_map(map_path)}}
  end

  @impl true
  def handle_call({:resolve, cwd}, _from, %{map: map} = state) do
    {:reply, resolve_client(cwd, map), state}
  end

  @impl true
  def handle_call(:reload, _from, %{path: path} = state) do
    {:reply, :ok, %{state | map: load_map(path)}}
  end

  defp load_map(path) do
    case File.read(path) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> %{"users" => %{}}
    end
  end

  defp resolve_client(nil, _map), do: "unknown"
  defp resolve_client("", _map), do: "unknown"

  defp resolve_client(cwd, %{"users" => users}) do
    case match_workspace_dirs(cwd, users) do
      {_best_path, best_client} ->
        case match_cwd_overrides(cwd, users) do
          nil -> best_client
          override -> override
        end
      nil ->
        case match_user_home(cwd, users) do
          nil -> "unknown"
          client -> client
        end
    end
  end

  defp match_workspace_dirs(cwd, users) do
    users
    |> Enum.flat_map(fn {_username, config} ->
      (config["workspace_dirs"] || %{})
      |> Enum.filter(fn {ws_path, _client} ->
        String.starts_with?(cwd, ws_path <> "/") or cwd == ws_path
      end)
    end)
    |> Enum.max_by(fn {ws_path, _} -> String.length(ws_path) end, fn -> nil end)
  end

  defp match_cwd_overrides(cwd, users) do
    parts = Path.split(cwd) |> MapSet.new()

    users
    |> Enum.find_value(fn {_username, config} ->
      (config["cwd_overrides"] || %{})
      |> Enum.find_value(fn {dirname, label} ->
        if MapSet.member?(parts, dirname), do: label
      end)
    end)
  end

  defp match_user_home(cwd, users) do
    users
    |> Enum.find_value(fn {_username, config} ->
      home = config["home"]
      if String.starts_with?(cwd, home <> "/") or cwd == home do
        parts = Path.split(cwd) |> MapSet.new()
        case Enum.find_value(config["cwd_overrides"] || %{}, fn {dirname, label} ->
          if MapSet.member?(parts, dirname), do: label
        end) do
          nil -> config["default_client"]
          override -> override
        end
      end
    end)
  end
end
