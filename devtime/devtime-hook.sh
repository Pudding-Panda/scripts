#!/usr/bin/env bash
# Claude Code hook — sends heartbeat to local devtime server.
# Runs on UserPromptSubmit. Fire-and-forget (background curl, no blocking).
# Install: add to settings.json hooks.UserPromptSubmit
#
# The hook payload arrives as JSON on stdin. A long-lived agent that re-prompts itself
# on a timer fires UserPromptSubmit exactly like a human does, so the prompt is matched
# against known automation markers and tagged event_type=auto. The report drops those;
# untagged rows stay event_type=heartbeat.

DEVTIME_PORT="${DEVTIME_PORT:-7879}"
DEVTIME_URL="http://127.0.0.1:${DEVTIME_PORT}/api/heartbeat"

payload=$(cat 2>/dev/null)

prompt=""
session_id=""
cwd=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
  prompt=$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null)
  session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
fi

# CLAUDE_SESSION_ID is not exported into the hook shell, so $$ (a fresh subshell PID)
# used to land in session_id and made every row look like its own session.
[ -z "$session_id" ] && session_id="${CLAUDE_SESSION_ID:-unknown}"
[ -z "$cwd" ] && cwd="$PWD"

event_type="heartbeat"
case "$prompt" in
  /loop*|*"<<autonomous-loop"*|*"[loop iteration"*|*"cheduled wakeup"*|"<task-notification>"*)
    event_type="auto"
    ;;
esac

# A prompt Claude Code re-injects on a timer repeats verbatim, so the same text twice in
# a row from one session is a loop tick, not a person typing.
if [ "$event_type" = "heartbeat" ] && [ -n "$prompt" ] && [ -n "$session_id" ]; then
  state_dir="${DEVTIME_STATE_DIR:-$HOME/.claude/.devtime}"
  mkdir -p "$state_dir" 2>/dev/null
  state_file="$state_dir/last-prompt-$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_-' '_')"
  hash=$(printf '%s' "$prompt" | cksum | cut -d' ' -f1)
  if [ -f "$state_file" ] && [ "$(cat "$state_file" 2>/dev/null)" = "$hash" ]; then
    event_type="auto"
  fi
  printf '%s' "$hash" > "$state_file" 2>/dev/null
fi

body=$(jq -nc --arg u "$USER" --arg c "$cwd" --arg s "$session_id" --arg e "$event_type" \
       --argjson t "$(date +%s)" \
       '{user:$u, cwd:$c, session_id:$s, event_type:$e, timestamp:$t}')

curl -sf -X POST "$DEVTIME_URL" \
  -H "Content-Type: application/json" \
  -d "$body" \
  --max-time 1 \
  >/dev/null 2>&1 &
