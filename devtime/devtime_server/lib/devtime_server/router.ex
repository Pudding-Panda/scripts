defmodule DevtimeServer.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  get "/api/health" do
    {:ok, [[count]]} = DevtimeServer.DB.query("SELECT COUNT(*) FROM heartbeats")
    send_json(conn, 200, %{status: "ok", heartbeats: count})
  end

  get "/api/report" do
    params = fetch_query_params(conn).query_params

    opts = [
      days: parse_int(params["days"], 7),
      interval: parse_int(params["interval"], 60),
      tolerance: parse_int(params["tolerance"], 30),
      from: parse_int(params["from"], nil),
      to: parse_int(params["to"], nil),
      client: params["client"],
      user: params["user"],
      exclude_machine: parse_bool(params["exclude_machine"], true),
      cadence_tolerance: parse_int(params["cadence_tolerance"], nil),
      cadence_min_run: parse_int(params["cadence_min_run"], nil)
    ] |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    report = DevtimeServer.Report.generate(opts)
    send_json(conn, 200, report)
  end

  get "/api/heartbeats" do
    params = fetch_query_params(conn).query_params
    days = parse_int(params["days"], 1)
    cutoff = System.system_time(:second) - days * 86400

    {:ok, rows} = DevtimeServer.DB.query(
      "SELECT id, ts, ts_epoch, user, client, project, cwd, session_id, event_type FROM heartbeats WHERE ts_epoch >= ?1 ORDER BY ts_epoch DESC LIMIT 100",
      [cutoff]
    )

    data = Enum.map(rows, fn [id, ts, ts_epoch, user, client, project, cwd, session_id, event_type] ->
      %{id: id, ts: ts, ts_epoch: ts_epoch, user: user, client: client, project: project, cwd: cwd, session_id: session_id, event_type: event_type}
    end)

    send_json(conn, 200, data)
  end

  post "/api/heartbeat" do
    body = conn.body_params

    cwd = body["cwd"] || ""
    user = body["user"] || "unknown"
    ts_epoch = body["timestamp"] || System.system_time(:second)
    ts_epoch = if is_binary(ts_epoch), do: String.to_float(ts_epoch), else: ts_epoch / 1
    client = body["client"] || DevtimeServer.ClientMap.resolve(cwd)

    ts_iso =
      ts_epoch
      |> trunc()
      |> DateTime.from_unix!()
      |> DateTime.to_iso8601()

    params = %{
      ts: ts_iso,
      ts_epoch: ts_epoch,
      user: user,
      client: client,
      project: body["project"],
      cwd: cwd,
      session_id: body["session_id"],
      event_type: body["event_type"]
    }

    case DevtimeServer.DB.insert_heartbeat(params) do
      {:ok, resolved_client} ->
        DevtimeServer.Wakapi.send_heartbeat(params)
        send_json(conn, 200, %{ok: true, client: resolved_client, user: user, ts: ts_iso})
      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/api/heartbeat/batch" do
    heartbeats_raw = conn.body_params["heartbeats"] || []

    heartbeats =
      Enum.map(heartbeats_raw, fn hb ->
        cwd = hb["cwd"] || ""
        ts_epoch = hb["timestamp"] || System.system_time(:second)
        ts_epoch = if is_binary(ts_epoch), do: String.to_float(ts_epoch), else: ts_epoch / 1
        client = hb["client"] || DevtimeServer.ClientMap.resolve(cwd)
        ts_iso = ts_epoch |> trunc() |> DateTime.from_unix!() |> DateTime.to_iso8601()

        %{
          ts: ts_iso,
          ts_epoch: ts_epoch,
          user: hb["user"] || "unknown",
          client: client,
          project: hb["project"],
          cwd: cwd,
          session_id: hb["session_id"],
          event_type: hb["event_type"]
        }
      end)

    case DevtimeServer.DB.insert_batch(heartbeats) do
      {:ok, count} ->
        send_json(conn, 200, %{ok: true, inserted: count})
      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/api/client-map/reload" do
    DevtimeServer.ClientMap.reload()
    send_json(conn, 200, %{ok: true, message: "client map reloaded"})
  end

  match _ do
    send_json(conn, 404, %{
      error: "not found",
      endpoints: [
        "GET  /api/health",
        "GET  /api/report?days=7&interval=60&tolerance=30&from=EPOCH&to=EPOCH&client=X&user=X&exclude_machine=1",
        "GET  /api/heartbeats?days=1",
        "POST /api/heartbeat",
        "POST /api/heartbeat/batch",
        "POST /api/client-map/reload"
      ]
    })
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_bool(nil, default), do: default
  defp parse_bool(val, _default) when val in ["0", "false", "no"], do: false
  defp parse_bool(val, _default) when val in ["1", "true", "yes"], do: true
  defp parse_bool(_val, default), do: default
end
