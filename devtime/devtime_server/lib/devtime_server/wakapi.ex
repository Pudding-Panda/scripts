defmodule DevtimeServer.Wakapi do
  @moduledoc """
  Forwards heartbeats to Wakapi using the WakaTime-compat API.
  Runs async — never blocks the main heartbeat ingestion.
  """

  require Logger

  def send_heartbeat(params) do
    Task.Supervisor.start_child(DevtimeServer.TaskSupervisor, fn ->
      do_send(params)
    end)
  end

  defp do_send(params) do
    config = Application.get_env(:devtime_server, :wakapi, [])
    url = Keyword.get(config, :url)
    api_key = Keyword.get(config, :api_key)

    if url && api_key do
      endpoint = String.trim_trailing(url, "/") <> "/compat/wakatime/v1/users/current/heartbeats"
      auth = Base.encode64(api_key)

      body = Jason.encode!(%{
        "entity" => params.cwd || "/unknown",
        "type" => "file",
        "time" => params.ts_epoch,
        "project" => params.client,
        "language" => "Claude",
        "category" => "coding",
        "user_agent" => "devtime-server/0.1.0"
      })

      case :httpc.request(
        :post,
        {String.to_charlist(endpoint), [{'Authorization', String.to_charlist("Basic #{auth}")}], 'application/json', String.to_charlist(body)},
        [ssl: [verify: :verify_none], timeout: 5000, connect_timeout: 3000],
        []
      ) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
          :ok
        {:ok, {{_, status, _}, _, resp_body}} ->
          Logger.warning("Wakapi returned #{status}: #{resp_body}")
        {:error, reason} ->
          Logger.warning("Wakapi request failed: #{inspect(reason)}")
      end
    end
  end
end
