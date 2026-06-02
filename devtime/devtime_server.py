#!/usr/bin/env python3
"""
Local devtime tracking server.
Receives heartbeats from Claude Code hooks, stores in SQLite,
reports time per client with independent concurrent tracking.

Port: 7879
DB: devtime.db (same directory)
"""

import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

DB_PATH = Path(__file__).parent / "devtime.db"
CLIENT_MAP_PATH = Path(__file__).parent / "client_map.json"
DEFAULT_PORT = 7879
DEFAULT_INTERVAL = 60  # minutes
DEFAULT_TOLERANCE = 30  # minutes


def load_client_map():
    if CLIENT_MAP_PATH.exists():
        with open(CLIENT_MAP_PATH) as f:
            return json.load(f)
    return {"users": {}}


def resolve_client(cwd, client_map):
    if not cwd:
        return "unknown"

    best_match = ""
    best_client = None
    for username, config in client_map["users"].items():
        for ws_path, ws_client in config.get("workspace_dirs", {}).items():
            if (cwd.startswith(ws_path + "/") or cwd == ws_path) and len(ws_path) > len(best_match):
                best_match = ws_path
                best_client = ws_client

    if best_client:
        for username, config in client_map["users"].items():
            parts = Path(cwd).parts
            for dirname, label in config.get("cwd_overrides", {}).items():
                if dirname in parts:
                    return label
        return best_client

    for username, config in client_map["users"].items():
        home = config["home"]
        if cwd.startswith(home + "/") or cwd == home:
            parts = Path(cwd).parts
            for dirname, label in config.get("cwd_overrides", {}).items():
                if dirname in parts:
                    return label
            return config["default_client"]

    return "unknown"


def init_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("""
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
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_heartbeats_ts ON heartbeats(ts_epoch)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_heartbeats_client ON heartbeats(client)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_heartbeats_user ON heartbeats(user)
    """)
    conn.commit()
    conn.close()


def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def compute_report(days=7, interval=60, tolerance=30, client_filter=None, user_filter=None):
    """Compute time report from heartbeats using gap-based session merging.
    Each client tracked independently — concurrent work on different clients
    yields separate time blocks."""
    conn = get_db()
    cutoff = time.time() - (days * 86400)

    query = "SELECT * FROM heartbeats WHERE ts_epoch >= ?"
    params = [cutoff]
    if client_filter:
        query += " AND client = ?"
        params.append(client_filter)
    if user_filter:
        query += " AND user = ?"
        params.append(user_filter)
    query += " ORDER BY ts_epoch ASC"

    rows = conn.execute(query, params).fetchall()
    conn.close()

    by_client = {}
    for row in rows:
        c = row["client"]
        if c not in by_client:
            by_client[c] = []
        by_client[c].append(row["ts_epoch"])

    interval_s = interval * 60
    tolerance_s = tolerance * 60
    results = {}

    for client, timestamps in by_client.items():
        if not timestamps:
            continue
        blocks = []
        block_start = timestamps[0]
        block_end = timestamps[0]

        for ts in timestamps[1:]:
            if ts - block_end <= interval_s:
                block_end = ts
            else:
                blocks.append((block_start, block_end + tolerance_s))
                block_start = ts
                block_end = ts
        blocks.append((block_start, block_end + tolerance_s))

        total_seconds = sum(end - start for start, end in blocks)
        results[client] = {
            "total_seconds": total_seconds,
            "total_human": format_duration(total_seconds),
            "sessions": len(blocks),
            "heartbeats": len(timestamps),
            "blocks": [
                {
                    "start": datetime.fromtimestamp(s, tz=timezone.utc).isoformat(),
                    "end": datetime.fromtimestamp(e, tz=timezone.utc).isoformat(),
                    "duration_seconds": e - s,
                }
                for s, e in blocks
            ],
        }

    total = sum(r["total_seconds"] for r in results.values())
    for client, data in results.items():
        data["share_pct"] = round(data["total_seconds"] / total * 100, 1) if total > 0 else 0

    by_day = {}
    for client, timestamps in by_client.items():
        for ts in timestamps:
            day = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d")
            if day not in by_day:
                by_day[day] = {}
            if client not in by_day[day]:
                by_day[day][client] = []
            by_day[day][client].append(ts)

    daily = {}
    for day, clients in sorted(by_day.items()):
        daily[day] = {}
        for client, timestamps in clients.items():
            timestamps.sort()
            blocks = []
            block_start = timestamps[0]
            block_end = timestamps[0]
            for ts in timestamps[1:]:
                if ts - block_end <= interval_s:
                    block_end = ts
                else:
                    blocks.append((block_start, block_end + tolerance_s))
                    block_start = ts
                    block_end = ts
            blocks.append((block_start, block_end + tolerance_s))
            secs = sum(end - start for start, end in blocks)
            daily[day][client] = {
                "total_seconds": secs,
                "total_human": format_duration(secs),
            }

    return {
        "period_days": days,
        "interval_minutes": interval,
        "tolerance_minutes": tolerance,
        "total_seconds": total,
        "total_human": format_duration(total),
        "by_client": dict(sorted(results.items(), key=lambda x: -x[1]["total_seconds"])),
        "by_day": daily,
    }


def format_duration(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    if h > 0:
        return f"{h}h {m:02d}m"
    return f"{m}m"


class DevtimeHandler(BaseHTTPRequestHandler):
    client_map = None

    def log_message(self, format, *args):
        pass

    def _send_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        if path == "/api/health":
            conn = get_db()
            count = conn.execute("SELECT COUNT(*) FROM heartbeats").fetchone()[0]
            conn.close()
            self._send_json({"status": "ok", "heartbeats": count, "db": str(DB_PATH)})

        elif path == "/api/report":
            days = int(params.get("days", [7])[0])
            interval = int(params.get("interval", [DEFAULT_INTERVAL])[0])
            tolerance = int(params.get("tolerance", [DEFAULT_TOLERANCE])[0])
            client = params.get("client", [None])[0]
            user = params.get("user", [None])[0]
            report = compute_report(days, interval, tolerance, client, user)
            self._send_json(report)

        elif path == "/api/heartbeats":
            days = int(params.get("days", [1])[0])
            cutoff = time.time() - (days * 86400)
            conn = get_db()
            rows = conn.execute(
                "SELECT * FROM heartbeats WHERE ts_epoch >= ? ORDER BY ts_epoch DESC LIMIT 100",
                [cutoff],
            ).fetchall()
            conn.close()
            self._send_json([dict(r) for r in rows])

        else:
            self._send_json({"error": "not found", "endpoints": [
                "GET /api/health",
                "GET /api/report?days=7&interval=60&tolerance=30&client=X&user=X",
                "GET /api/heartbeats?days=1",
                "POST /api/heartbeat",
            ]}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/api/heartbeat":
            try:
                data = self._read_body()
            except Exception:
                self._send_json({"error": "invalid json"}, 400)
                return

            cwd = data.get("cwd", "")
            user = data.get("user", os.environ.get("USER", "unknown"))
            session_id = data.get("session_id", "")
            project = data.get("project", "")
            event_type = data.get("event_type", "heartbeat")
            ts_epoch = data.get("timestamp", time.time())

            if not self.__class__.client_map:
                self.__class__.client_map = load_client_map()

            client = data.get("client") or resolve_client(cwd, self.__class__.client_map)
            ts_iso = datetime.fromtimestamp(ts_epoch, tz=timezone.utc).isoformat()

            conn = get_db()
            conn.execute(
                "INSERT INTO heartbeats (ts, ts_epoch, user, client, project, cwd, session_id, event_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [ts_iso, ts_epoch, user, client, project, cwd, session_id, event_type],
            )
            conn.commit()
            conn.close()

            self._send_json({"ok": True, "client": client, "user": user, "ts": ts_iso})

        elif path == "/api/heartbeat/batch":
            try:
                data = self._read_body()
                heartbeats = data.get("heartbeats", [])
            except Exception:
                self._send_json({"error": "invalid json"}, 400)
                return

            if not self.__class__.client_map:
                self.__class__.client_map = load_client_map()

            conn = get_db()
            inserted = 0
            for hb in heartbeats:
                cwd = hb.get("cwd", "")
                user = hb.get("user", "unknown")
                client = hb.get("client") or resolve_client(cwd, self.__class__.client_map)
                ts_epoch = hb.get("timestamp", time.time())
                ts_iso = datetime.fromtimestamp(ts_epoch, tz=timezone.utc).isoformat()
                conn.execute(
                    "INSERT INTO heartbeats (ts, ts_epoch, user, client, project, cwd, session_id, event_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    [ts_iso, ts_epoch, user, client, hb.get("project", ""), cwd, hb.get("session_id", ""), hb.get("event_type", "heartbeat")],
                )
                inserted += 1
            conn.commit()
            conn.close()
            self._send_json({"ok": True, "inserted": inserted})

        else:
            self._send_json({"error": "not found"}, 404)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    init_db()
    print(f"devtime server starting on :{port}, db={DB_PATH}", flush=True)

    server = HTTPServer(("127.0.0.1", port), DevtimeHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")
        server.server_close()


if __name__ == "__main__":
    main()
