#!/usr/bin/env bash
# Claude Code hook — sends heartbeat to local devtime server.
# Runs on UserPromptSubmit. Fire-and-forget (background curl, no blocking).
# Install: add to settings.json hooks.UserPromptSubmit

DEVTIME_PORT="${DEVTIME_PORT:-7879}"
DEVTIME_URL="http://127.0.0.1:${DEVTIME_PORT}/api/heartbeat"

curl -sf -X POST "$DEVTIME_URL" \
  -H "Content-Type: application/json" \
  -d "{\"user\":\"$USER\",\"cwd\":\"$PWD\",\"session_id\":\"${CLAUDE_SESSION_ID:-$$}\",\"timestamp\":$(date +%s.%N)}" \
  --max-time 1 \
  >/dev/null 2>&1 &
