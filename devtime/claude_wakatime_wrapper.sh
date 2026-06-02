#!/usr/bin/env bash
#
# Script 4: Claude Code Wakatime Wrapper
#
# Wraps `claude` invocations with wakatime heartbeats tagged by client.
# Resolves client from OS user + cwd using the same mapping logic.
#
# Installation:
#   1. Install wakatime-cli: pip3 install wakatime
#   2. Configure ~/.wakatime.cfg to point to devtime.apps.puddi.ng
#   3. Add alias: alias claude='/path/to/claude_wakatime_wrapper.sh'
#      Or symlink this to ~/bin/claude-tracked
#
# Pre-implementation notes (problem points identified):
#   - wakatime-cli needs to be installed on the system
#   - ~/.wakatime.cfg must point to self-hosted Wakapi, not wakapi.dev
#   - Client resolution from cwd needs the client_map.json
#   - Heartbeats are sent every 2 minutes while claude is running
#   - The wrapper captures the PID and sends heartbeats in background
#   - On exit, final heartbeat is sent
#
# PROBLEM POINTS:
#   P1: wakatime-cli may not be installed — need provisioning step
#   P2: wakatime uses "project" field from folder name — we override with --project
#   P3: wakatime "language" field meaningless for CLI work — we set it to "Claude Code"
#   P4: Multiple concurrent claude sessions = multiple wrappers = heartbeat collision?
#       → wakatime deduplicates by timestamp, so this is fine
#   P5: If claude is run as different OS users, each needs their own ~/.wakatime.cfg
#   P6: Wakapi "labels" feature can group projects → client. Alternative to --project override.
#       → Wakapi supports project labels in the web UI, OR we can use naming convention:
#         project = "client/subproject" (e.g., "ppanda/rebecc-ai", "zeroum/provisioner")
#         Then filter by prefix in Wakapi dashboard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_MAP="$SCRIPT_DIR/client_map.json"
HEARTBEAT_INTERVAL=120  # seconds

resolve_client() {
    local cwd="$1"
    local user
    user="$(whoami)"

    # Use python to resolve from client_map.json
    python3 -c "
import json, os, sys

cwd = '$cwd'
user = '$user'
if user == 'root': user = 'root'

with open('$CLIENT_MAP') as f:
    cm = json.load(f)

config = cm['users'].get(user, {'default_client': user, 'cwd_overrides': {}})
default = config['default_client']

parts = cwd.split('/')
for dirname, label in config.get('cwd_overrides', {}).items():
    if dirname in parts:
        print(label)
        sys.exit(0)

print(default)
" 2>/dev/null || echo "unknown"
}

send_heartbeat() {
    local project="$1"
    local entity="$2"

    if command -v wakatime-cli &>/dev/null; then
        wakatime-cli --entity "$entity" \
            --entity-type "app" \
            --project "$project" \
            --language "Claude Code" \
            --plugin "claude-wrapper" \
            --write 2>/dev/null || true
    elif command -v wakatime &>/dev/null; then
        wakatime --entity "$entity" \
            --entity-type "app" \
            --project "$project" \
            --language "Claude Code" \
            --plugin "claude-wrapper" \
            --write 2>/dev/null || true
    else
        # Fallback: direct API heartbeat via curl
        local api_key
        api_key=$(python3 -c "
import configparser, os
c = configparser.ConfigParser()
c.read(os.path.expanduser('~/.wakatime.cfg'))
print(c.get('settings', 'api_key', fallback=''))
" 2>/dev/null)

        local api_url
        api_url=$(python3 -c "
import configparser, os
c = configparser.ConfigParser()
c.read(os.path.expanduser('~/.wakatime.cfg'))
print(c.get('settings', 'api_url', fallback='https://devtime.apps.puddi.ng:3000/api'))
" 2>/dev/null)

        if [ -n "$api_key" ]; then
            local now
            now=$(python3 -c "import time; print(time.time())")
            curl -s -X POST "${api_url}/users/current/heartbeats" \
                -H "Authorization: Basic $(echo -n "$api_key" | base64)" \
                -H "Content-Type: application/json" \
                -d "{
                    \"entity\": \"$entity\",
                    \"type\": \"app\",
                    \"time\": $now,
                    \"project\": \"$project\",
                    \"language\": \"Claude Code\",
                    \"is_write\": true
                }" 2>/dev/null || true
        fi
    fi
}

heartbeat_loop() {
    local project="$1"
    local entity="$2"
    local pid="$3"

    while kill -0 "$pid" 2>/dev/null; do
        send_heartbeat "$project" "$entity"
        sleep "$HEARTBEAT_INTERVAL"
    done
}

main() {
    local cwd
    cwd="$(pwd)"
    local client
    client="$(resolve_client "$cwd")"

    # Build project name as "client/dirname" for Wakapi grouping
    local dirname
    dirname="$(basename "$cwd")"
    local project="${client}/${dirname}"

    # Entity = the working directory (what we're "editing")
    local entity="$cwd"

    echo "[devtime] Tracking: project=$project client=$client"

    # Send initial heartbeat
    send_heartbeat "$project" "$entity"

    # Find real claude binary (skip this wrapper)
    local claude_bin
    claude_bin=$(which -a claude 2>/dev/null | grep -v "$(readlink -f "${BASH_SOURCE[0]}")" | head -1)
    if [ -z "$claude_bin" ]; then
        # Try common locations
        for p in /usr/local/bin/claude /usr/bin/claude "$HOME/.local/bin/claude" "$HOME/.claude/bin/claude"; do
            if [ -x "$p" ]; then
                claude_bin="$p"
                break
            fi
        done
    fi

    if [ -z "$claude_bin" ]; then
        echo "[devtime] ERROR: Cannot find claude binary"
        exit 1
    fi

    # Start claude in foreground, heartbeat in background
    "$claude_bin" "$@" &
    local claude_pid=$!

    heartbeat_loop "$project" "$entity" "$claude_pid" &
    local hb_pid=$!

    # Wait for claude to finish
    wait "$claude_pid" 2>/dev/null
    local exit_code=$?

    # Kill heartbeat loop
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true

    # Final heartbeat
    send_heartbeat "$project" "$entity"

    echo "[devtime] Session ended: project=$project"
    return $exit_code
}

main "$@"
