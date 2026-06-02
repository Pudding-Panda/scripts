#!/usr/bin/env python3
"""
Script 2: Git Commit Time Estimator

Estimates development time per client by analyzing git commit timestamps.
Groups commits within GAP_THRESHOLD into work sessions.
Adds FIRST_COMMIT_MINUTES for the first commit in each session
(assuming some work happened before the first commit).

Usage:
    python3 git_hours_report.py [--days 7] [--all-time] [--csv]
"""

import json
import os
import subprocess
import sys
import argparse
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from pathlib import Path

GAP_THRESHOLD_MINUTES = 120
FIRST_COMMIT_MINUTES = 30

SCRIPT_DIR = Path(__file__).parent
CLIENT_MAP_FILE = SCRIPT_DIR / "client_map.json"


def load_client_map():
    with open(CLIENT_MAP_FILE) as f:
        return json.load(f)


def find_git_repos(search_paths):
    repos = []
    for base in search_paths:
        if not os.path.isdir(base):
            continue
        for root, dirs, files in os.walk(base):
            if ".git" in dirs:
                repos.append(root)
                dirs.remove(".git")
            depth = root[len(base):].count(os.sep)
            if depth >= 3:
                dirs.clear()
    return repos


def get_commits(repo_path, since_date):
    """Get commit timestamps and authors from a repo."""
    cmd = [
        "git", "-C", repo_path, "log", "--all",
        f"--since={since_date}",
        "--format=%aI|%an|%H|%s",
        "--no-merges"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return []
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    commits = []
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        parts = line.split("|", 3)
        if len(parts) < 4:
            continue
        try:
            ts = datetime.fromisoformat(parts[0])
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
            commits.append({
                "ts": ts,
                "author": parts[1],
                "hash": parts[2][:8],
                "subject": parts[3],
            })
        except ValueError:
            continue

    return commits


def resolve_repo_client(repo_path, username, user_config):
    basename = os.path.basename(repo_path)

    overrides = user_config.get("cwd_overrides", {})
    if basename in overrides:
        return overrides[basename]

    return user_config["default_client"]


def estimate_sessions(commits):
    """Group commits into work sessions, estimate time."""
    if not commits:
        return []

    commits.sort(key=lambda c: c["ts"])
    sessions = []

    current = {
        "start": commits[0]["ts"],
        "end": commits[0]["ts"],
        "commits": [commits[0]],
    }

    for commit in commits[1:]:
        gap = (commit["ts"] - current["end"]).total_seconds() / 60

        if gap > GAP_THRESHOLD_MINUTES:
            sessions.append(current)
            current = {
                "start": commit["ts"],
                "end": commit["ts"],
                "commits": [commit],
            }
        else:
            current["end"] = commit["ts"]
            current["commits"].append(commit)

    sessions.append(current)

    for s in sessions:
        duration = (s["end"] - s["start"]).total_seconds() / 60
        s["duration_min"] = duration + FIRST_COMMIT_MINUTES

    return sessions


def scan_all_repos(client_map, since_date):
    """Scan all configured users' repos."""
    all_data = []

    for username, config in client_map["users"].items():
        home = config["home"]
        search_paths = [home]
        if username == "root":
            search_paths = [os.path.join(home, "workspace", "ppanda")]

        repos = find_git_repos(search_paths)

        for repo in repos:
            commits = get_commits(repo, since_date)
            if not commits:
                continue

            client = resolve_repo_client(repo, username, config)
            sessions = estimate_sessions(commits)

            for s in sessions:
                all_data.append({
                    "client": client,
                    "user": username,
                    "repo": os.path.basename(repo),
                    "start": s["start"],
                    "end": s["end"],
                    "duration_min": s["duration_min"],
                    "commit_count": len(s["commits"]),
                })

    return all_data


def format_duration(minutes):
    hours = int(minutes // 60)
    mins = int(minutes % 60)
    if hours > 0:
        return f"{hours}h {mins:02d}m"
    return f"{mins}m"


def print_report(data, days, csv_mode=False):
    client_time = defaultdict(float)
    client_commits = defaultdict(int)
    client_repos = defaultdict(set)
    daily_breakdown = defaultdict(lambda: defaultdict(float))

    for d in data:
        client_time[d["client"]] += d["duration_min"]
        client_commits[d["client"]] += d["commit_count"]
        client_repos[d["client"]].add(d["repo"])
        day_key = d["start"].strftime("%Y-%m-%d")
        daily_breakdown[day_key][d["client"]] += d["duration_min"]

    if csv_mode:
        print("client,minutes,commits,repos,hours")
        for client in sorted(client_time, key=client_time.get, reverse=True):
            mins = client_time[client]
            repos = ",".join(sorted(client_repos[client]))
            print(f"{client},{mins:.0f},{client_commits[client]},\"{repos}\",{mins/60:.1f}")
        return

    total_min = sum(client_time.values())
    total_commits = sum(client_commits.values())

    print(f"\n{'='*60}")
    print(f"  GIT HOURS REPORT — Last {days} days")
    print(f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"  Method: commit gap analysis (gap>{GAP_THRESHOLD_MINUTES}m = new session)")
    print(f"  First-commit bonus: {FIRST_COMMIT_MINUTES}m per session")
    print(f"{'='*60}")

    if not data:
        print("\n  No git commits found in this period.\n")
        return

    print(f"\n  Total: ~{format_duration(total_min)} across {total_commits} commits\n")

    print(f"  {'Client':<25} {'Est. Time':>10} {'Commits':>8} {'Repos':>6}")
    print(f"  {'-'*25} {'-'*10} {'-'*8} {'-'*6}")

    for client in sorted(client_time, key=client_time.get, reverse=True):
        mins = client_time[client]
        print(f"  {client:<25} {format_duration(mins):>10} {client_commits[client]:>8} {len(client_repos[client]):>6}")
        for repo in sorted(client_repos[client]):
            print(f"    └ {repo}")

    if daily_breakdown:
        print(f"\n  {'--- Daily Breakdown ---':^50}")
        for day in sorted(daily_breakdown.keys()):
            day_total = sum(daily_breakdown[day].values())
            print(f"\n  {day} (~{format_duration(day_total)} total)")
            for client in sorted(daily_breakdown[day], key=daily_breakdown[day].get, reverse=True):
                mins = daily_breakdown[day][client]
                print(f"    {client:<23} ~{format_duration(mins):>10}")

    print(f"\n{'='*60}\n")


def main():
    parser = argparse.ArgumentParser(description="Git commit time estimator")
    parser.add_argument("--days", type=int, default=7, help="Days to look back (default: 7)")
    parser.add_argument("--all-time", action="store_true", help="Parse all commits")
    parser.add_argument("--csv", action="store_true", help="Output CSV format")
    args = parser.parse_args()

    if args.all_time:
        since_date = "2020-01-01"
        days_label = "all time"
    else:
        since_dt = datetime.now() - timedelta(days=args.days)
        since_date = since_dt.strftime("%Y-%m-%d")
        days_label = args.days

    client_map = load_client_map()
    data = scan_all_repos(client_map, since_date)
    data.sort(key=lambda d: d["start"])
    print_report(data, days_label, csv_mode=args.csv)


if __name__ == "__main__":
    main()
