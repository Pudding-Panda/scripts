import Config

config :devtime_server,
  port: String.to_integer(System.get_env("DEVTIME_PORT") || "7879"),
  db_path: System.get_env("DEVTIME_DB_PATH") || "/data/devtime.db",
  client_map_path: System.get_env("DEVTIME_CLIENT_MAP") || "/app/config/client_map.json",
  wakapi: [
    url: System.get_env("WAKAPI_URL"),
    api_key: System.get_env("WAKAPI_API_KEY")
  ]
