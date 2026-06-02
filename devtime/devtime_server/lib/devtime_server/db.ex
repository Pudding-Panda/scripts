defmodule DevtimeServer.DB do
  use GenServer

  @db_path "devtime.db"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def insert_heartbeat(params) do
    GenServer.call(__MODULE__, {:insert, params})
  end

  def insert_batch(heartbeats) do
    GenServer.call(__MODULE__, {:insert_batch, heartbeats}, 30_000)
  end

  def query(sql, params \\ []) do
    GenServer.call(__MODULE__, {:query, sql, params}, 15_000)
  end

  @impl true
  def init(_opts) do
    db_path = Application.get_env(:devtime_server, :db_path, @db_path)
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL")

    :ok = Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS heartbeats (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL,
      ts_epoch REAL NOT NULL,
      user TEXT NOT NULL,
      client TEXT NOT NULL,
      project TEXT DEFAULT '',
      cwd TEXT DEFAULT '',
      session_id TEXT DEFAULT '',
      event_type TEXT DEFAULT 'heartbeat'
    )
    """)

    :ok = Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_hb_ts ON heartbeats(ts_epoch)")
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_hb_client ON heartbeats(client)")
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_hb_user ON heartbeats(user)")

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:insert, params}, _from, %{conn: conn} = state) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn,
      "INSERT INTO heartbeats (ts, ts_epoch, user, client, project, cwd, session_id, event_type) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"
    )

    :ok = Exqlite.Sqlite3.bind(stmt, [
      params.ts,
      params.ts_epoch,
      params.user,
      params.client,
      params.project || "",
      params.cwd || "",
      params.session_id || "",
      params.event_type || "heartbeat"
    ])

    result = case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> {:ok, params.client}
      {:error, reason} -> {:error, reason}
    end

    Exqlite.Sqlite3.release(conn, stmt)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:insert_batch, heartbeats}, _from, %{conn: conn} = state) do
    :ok = Exqlite.Sqlite3.execute(conn, "BEGIN")

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn,
      "INSERT INTO heartbeats (ts, ts_epoch, user, client, project, cwd, session_id, event_type) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"
    )

    count = Enum.reduce(heartbeats, 0, fn params, acc ->
      :ok = Exqlite.Sqlite3.bind(stmt, [
        params.ts, params.ts_epoch, params.user, params.client,
        params.project || "", params.cwd || "",
        params.session_id || "", params.event_type || "heartbeat"
      ])
      case Exqlite.Sqlite3.step(conn, stmt) do
        :done -> acc + 1
        _ -> acc
      end
    end)

    Exqlite.Sqlite3.release(conn, stmt)
    :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    if params != [] do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
    end

    rows = fetch_all(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)
    {:reply, {:ok, rows}, state}
  end

  defp fetch_all(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    Exqlite.Sqlite3.close(conn)
  end
end
