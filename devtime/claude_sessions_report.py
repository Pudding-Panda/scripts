#!/usr/bin/env python3
"""
Claude Code Session Time Tracker

Parses Claude Code JSONL transcripts to calculate time spent per client.

Algorithm:
  1. Collect all messages with timestamps from all JSONL files
  2. Group by client (resolved from cwd)
  3. Per client, sort messages chronologically
  4. Walk messages: if gap to next message <= INTERVAL, they're in the same
     work block. If gap > INTERVAL, close the block and start a new one.
  5. Block duration = (last_msg - first_msg) + TOLERANCE
     TOLERANCE accounts for time spent processing/reading the last response.
  6. Blocks don't cross day boundaries.

Usage:
    python3 claude_sessions_report.py [--days 7] [--all-time] [--csv]
    python3 claude_sessions_report.py --interval 60 --tolerance 30
"""

import json
import os
import argparse
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
CLIENT_MAP_FILE = SCRIPT_DIR / "client_map.json"


def load_client_map():
    with open(CLIENT_MAP_FILE) as f:
        return json.load(f)


def resolve_client(cwd, client_map):
    if not cwd:
        return "unknown"

    # Check workspace_dirs first (longest prefix match)
    best_match = ""
    best_client = None
    for username, config in client_map["users"].items():
        for ws_path, ws_client in config.get("workspace_dirs", {}).items():
            if (cwd.startswith(ws_path + "/") or cwd == ws_path) and len(ws_path) > len(best_match):
                best_match = ws_path
                best_client = ws_client

    # Within a matched workspace, still check cwd_overrides for sub-project detail
    if best_client:
        for username, config in client_map["users"].items():
            parts = Path(cwd).parts
            for dirname, label in config.get("cwd_overrides", {}).items():
                if dirname in parts:
                    return label
        return best_client

    # Fall back to user home detection
    for username, config in client_map["users"].items():
        home = config["home"]
        if cwd.startswith(home + "/") or cwd == home:
            parts = Path(cwd).parts
            for dirname, label in config.get("cwd_overrides", {}).items():
                if dirname in parts:
                    return label
            return config["default_client"]

    return "unknown"


def collect_messages(client_map, cutoff_dt):
    """Collect all messages from all users' JSONL files, resolve client per message."""
    messages = []

    for username, config in client_map["users"].items():
        home = config["home"]
        projects_dir = os.path.join(home, ".claude", "projects")

        if not os.path.isdir(projects_dir):
            continue

        for root, dirs, files in os.walk(projects_dir):
            dirs[:] = [d for d in dirs if d not in ("memory", "subagents", "tool-results")]
            for fname in files:
                if not fname.endswith(".jsonl"):
                    continue
                fpath = os.path.join(root, fname)

                try:
                    with open(fpath) as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                entry = json.loads(line)
                            except json.JSONDecodeError:
                                continue

                            ts_str = entry.get("timestamp")
                            if not ts_str:
                                continue

                            msg_type = entry.get("type", "")
                            if msg_type not in ("user", "assistant"):
                                continue

                            try:
                                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                            except (ValueError, AttributeError):
                                continue

                            if ts < cutoff_dt:
                                continue

                            cwd = entry.get("cwd", "")
                            client = resolve_client(cwd, client_map)
                            messages.append({
                                "ts": ts,
                                "client": client,
                                "user": username,
                            })
                except (OSError, PermissionError):
                    continue

    return messages


def build_work_blocks(messages, interval_min, tolerance_min):
    """Group messages into work blocks per client.

    Messages from the same client within interval_min of each other
    belong to the same block. Block duration = span + tolerance.
    Blocks don't cross calendar day boundaries.
    """
    by_client = defaultdict(list)
    for m in messages:
        by_client[m["client"]].append(m)

    all_blocks = []

    for client, msgs in by_client.items():
        msgs.sort(key=lambda m: m["ts"])

        block_start = msgs[0]["ts"]
        block_last = msgs[0]["ts"]
        block_count = 1

        for msg in msgs[1:]:
            gap_min = (msg["ts"] - block_last).total_seconds() / 60
            crosses_day = msg["ts"].date() != block_last.date()

            if gap_min > interval_min or crosses_day:
                span_min = (block_last - block_start).total_seconds() / 60
                duration_min = span_min + tolerance_min
                all_blocks.append({
                    "client": client,
                    "start": block_start,
                    "end": block_last,
                    "duration_min": duration_min,
                    "msg_count": block_count,
                })

                block_start = msg["ts"]
                block_last = msg["ts"]
                block_count = 1
            else:
                block_last = msg["ts"]
                block_count += 1

        span_min = (block_last - block_start).total_seconds() / 60
        duration_min = span_min + tolerance_min
        all_blocks.append({
            "client": client,
            "start": block_start,
            "end": block_last,
            "duration_min": duration_min,
            "msg_count": block_count,
        })

    return all_blocks


def format_duration(minutes):
    hours = int(minutes // 60)
    mins = int(minutes % 60)
    if hours > 0:
        return f"{hours}h {mins:02d}m"
    return f"{mins}m"


def print_report(blocks, days, interval_min, tolerance_min, csv_mode=False):
    client_time = defaultdict(float)
    client_blocks = defaultdict(int)
    client_msgs = defaultdict(int)
    daily_breakdown = defaultdict(lambda: defaultdict(float))

    for b in blocks:
        client_time[b["client"]] += b["duration_min"]
        client_blocks[b["client"]] += 1
        client_msgs[b["client"]] += b["msg_count"]
        day_key = b["start"].strftime("%Y-%m-%d")
        daily_breakdown[day_key][b["client"]] += b["duration_min"]

    if csv_mode:
        print("client,minutes,blocks,messages,hours")
        for client in sorted(client_time, key=client_time.get, reverse=True):
            mins = client_time[client]
            print(f"{client},{mins:.0f},{client_blocks[client]},{client_msgs[client]},{mins/60:.1f}")
        return

    total_min = sum(client_time.values())
    total_blocks = sum(client_blocks.values())
    total_msgs = sum(client_msgs.values())

    print(f"\n{'='*65}")
    print(f"  CLAUDE CODE TIME REPORT — Last {days} days")
    print(f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"  Interval: {interval_min}m | Tolerance: {tolerance_min}m")
    print(f"{'='*65}")

    if not blocks:
        print("\n  No Claude Code sessions found in this period.\n")
        return

    print(f"\n  Total: {format_duration(total_min)} across {total_blocks} blocks ({total_msgs} messages)\n")

    print(f"  {'Client':<25} {'Time':>10} {'Blocks':>8} {'Msgs':>7} {'%':>6}")
    print(f"  {'-'*25} {'-'*10} {'-'*8} {'-'*7} {'-'*6}")

    for client in sorted(client_time, key=client_time.get, reverse=True):
        mins = client_time[client]
        pct = (mins / total_min * 100) if total_min > 0 else 0
        print(f"  {client:<25} {format_duration(mins):>10} {client_blocks[client]:>8} {client_msgs[client]:>7} {pct:>5.1f}%")

    if daily_breakdown:
        print(f"\n  {'--- Daily Breakdown ---':^55}")
        for day in sorted(daily_breakdown.keys()):
            day_total = sum(daily_breakdown[day].values())
            print(f"\n  {day} ({format_duration(day_total)} total)")
            for client in sorted(daily_breakdown[day], key=daily_breakdown[day].get, reverse=True):
                mins = daily_breakdown[day][client]
                print(f"    {client:<23} {format_duration(mins):>10}")

    print(f"\n{'='*65}\n")


def main():
    parser = argparse.ArgumentParser(description="Claude Code session time tracker")
    parser.add_argument("--days", type=int, default=7, help="Days to look back (default: 7)")
    parser.add_argument("--all-time", action="store_true", help="Parse all available sessions")
    parser.add_argument("--csv", action="store_true", help="Output CSV format")
    parser.add_argument("--interval", type=int, default=60, help="Max gap (minutes) between messages in same block (default: 60)")
    parser.add_argument("--tolerance", type=int, default=30, help="Minutes added after last message in block (default: 30)")
    args = parser.parse_args()

    if args.all_time:
        cutoff_dt = datetime(2020, 1, 1, tzinfo=timezone.utc)
        days_label = "all time"
    else:
        cutoff_dt = datetime.now(tz=timezone.utc) - timedelta(days=args.days)
        days_label = args.days

    client_map = load_client_map()
    messages = collect_messages(client_map, cutoff_dt)
    blocks = build_work_blocks(messages, args.interval, args.tolerance)
    blocks.sort(key=lambda b: b["start"])
    print_report(blocks, days_label, args.interval, args.tolerance, csv_mode=args.csv)


if __name__ == "__main__":
    main()
