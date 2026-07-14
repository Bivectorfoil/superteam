#!/bin/bash
# watchdog-daemon.sh - Standalone watchdog for Superteam pipeline
#
# Replaces Claude Code's ScheduleWakeup API with a platform-independent
# background process that monitors pipeline health and triggers recovery.
#
# Usage:
#   bash platform/watchdog-daemon.sh [interval_seconds]
#   bash platform/watchdog-daemon.sh --once          # Single check, then exit
#   bash platform/watchdog-daemon.sh --status         # Show current status
#
# Default interval: 1200 seconds (20 minutes)
#
# The watchdog:
# 1. Checks if pipeline is done (phase=complete or active_agents empty)
# 2. Checks Manager heartbeat (state.json mtime)
# 3. On stall detection: sends relaunch signal via platform adapter
# 4. On consecutive stalls: spawns fresh Orchestrator
#
# Signal files:
#   .superteam/signals/watchdog-status.json  - Current watchdog status
#   .superteam/signals/watchdog-relaunch     - Relaunch trigger file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPERTEAM_DIR="${SUPERTEAM_DIR:-.superteam}"
STATE_FILE="$SUPERTEAM_DIR/state.json"
SIGNAL_DIR="$SUPERTEAM_DIR/signals"
STATUS_FILE="$SIGNAL_DIR/watchdog-status.json"
STALL_COUNT_FILE="$SIGNAL_DIR/watchdog-stall-count"
LOCK_FILE="$SIGNAL_DIR/watchdog.lock"

INTERVAL="${1:-1200}"
STALL_THRESHOLD=1200  # seconds before considering state.json stale
MAX_STALLS=2          # consecutive stalls before spawning fresh orchestrator

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [watchdog] $*"
}

ensure_dirs() {
  mkdir -p "$SUPERTEAM_DIR" "$SIGNAL_DIR"
}

get_stall_count() {
  if [ -f "$STALL_COUNT_FILE" ]; then
    cat "$STALL_COUNT_FILE"
  else
    echo "0"
  fi
}

set_stall_count() {
  echo "$1" > "$STALL_COUNT_FILE"
}

write_status() {
  local status="$1"
  local detail="${2:-}"
  cat > "$STATUS_FILE" <<EOF
{
  "status": "$status",
  "detail": "$detail",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "interval": $INTERVAL,
  "stall_count": $(get_stall_count)
}
EOF
}

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      log "Another watchdog is running (PID $lock_pid). Exiting."
      exit 0
    fi
    log "Stale lock file found. Removing."
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# ─────────────────────────────────────────────────────────────────────────────
# Pipeline State Checks
# ─────────────────────────────────────────────────────────────────────────────

is_pipeline_done() {
  if [ ! -f "$STATE_FILE" ]; then
    return 1  # not done, just not started
  fi

  local phase
  phase="$(jq -r '.phase // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")"

  if [ "$phase" = "complete" ]; then
    return 0
  fi

  local active_count
  active_count="$(jq -r '.agents.active_agents | length' "$STATE_FILE" 2>/dev/null || echo "0")"
  if [ "$active_count" = "0" ] && [ "$phase" != "pm" ]; then
    return 0
  fi

  return 1
}

is_state_fresh() {
  if [ ! -f "$STATE_FILE" ]; then
    return 1
  fi

  local mtime
  if [[ "$OSTYPE" == "darwin"* ]]; then
    mtime="$(stat -f %m "$STATE_FILE" 2>/dev/null || echo 0)"
  else
    mtime="$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)"
  fi

  local now
  now="$(date +%s)"
  local age=$((now - mtime))

  [ "$age" -lt "$STALL_THRESHOLD" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Recovery Actions
# ─────────────────────────────────────────────────────────────────────────────

send_relaunch_to_orchestrator() {
  log "Sending RELAUNCH signal to Orchestrator"

  local form_name
  form_name="$(jq -r '.session.task_form // "engineering"' "$STATE_FILE" 2>/dev/null || echo "engineering")"
  local form_dir
  form_dir="$(jq -r '.session.form_dir // "task-forms/engineering"' "$STATE_FILE" 2>/dev/null || echo "task-forms/engineering")"

  # Read the original user request from events.jsonl if available
  local user_request
  user_request="$(jq -r 'select(.type=="user_request") | .payload.request' "$SUPERTEAM_DIR/events.jsonl" 2>/dev/null | tail -1 || echo "")"

  # Write relaunch signal
  cat > "$SIGNAL_DIR/watchdog-relaunch" <<SIGNAL
{
  "action": "relaunch",
  "target": "orchestrator",
  "reason": "state.json stale for >${STALL_THRESHOLD}s",
  "stall_count": $(get_stall_count),
  "form_name": "$form_name",
  "form_dir": "$form_dir",
  "user_request": $(echo "$user_request" | jq -Rs .),
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL

  # Also use platform adapter if available
  if [ -f "$SCRIPT_DIR/platform-adapter.sh" ]; then
    source "$SCRIPT_DIR/platform-adapter.sh"
    platform_send_message "orchestrator" "WATCHDOG RELAUNCH: state.json has not been updated in 20+ minutes. The pipeline appears stalled. Task form: $form_name. Form dir: $form_dir. Read .superteam/state.json for current state and resume." 2>/dev/null || true
  fi
}

spawn_fresh_orchestrator() {
  log "Spawning fresh Orchestrator (stall count >= $MAX_STALLS)"

  local form_name
  form_name="$(jq -r '.session.task_form // "engineering"' "$STATE_FILE" 2>/dev/null || echo "engineering")"
  local form_dir
  form_dir="$(jq -r '.session.form_dir // "task-forms/engineering"' "$STATE_FILE" 2>/dev/null || echo "task-forms/engineering")"

  # Remove old orchestrator from active_agents
  if [ -f "$STATE_FILE" ]; then
    jq '.agents.active_agents = [.agents.active_agents[] | select(. != "orchestrator")]' "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi

  # Write spawn signal
  cat > "$SIGNAL_DIR/spawn-orchestrator.json" <<SIGNAL
{
  "action": "spawn",
  "name": "orchestrator",
  "agent_def": "agents/orchestrator.md",
  "context": "RELAUNCH - pipeline recovered from stall. Read .superteam/state.json for current state.",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL

  # Use platform adapter if available
  if [ -f "$SCRIPT_DIR/platform-adapter.sh" ]; then
    source "$SCRIPT_DIR/platform-adapter.sh"
    platform_spawn_agent "orchestrator" "agents/orchestrator.md" "RELAUNCH - pipeline recovered from stall." 2>/dev/null || true
  fi

  # Reset stall count
  set_stall_count 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Check Loop
# ─────────────────────────────────────────────────────────────────────────────

run_check() {
  log "Running watchdog check..."

  # 1. Check if pipeline is done
  if is_pipeline_done; then
    log "Pipeline is complete. Watchdog stopping."
    write_status "complete" "Pipeline finished"
    return 0  # signal to stop the loop
  fi

  # 2. Check if state.json exists
  if [ ! -f "$STATE_FILE" ]; then
    log "State file not found. Pipeline may not be initialized."
    write_status "waiting" "No state.json"
    return 1  # continue watching
  fi

  # 3. Check Manager heartbeat
  if is_state_fresh; then
    log "State is fresh. Pipeline healthy."
    set_stall_count 0
    write_status "healthy" "Manager heartbeat active"
    return 1  # continue watching
  fi

  # 4. Stall detected
  local stall_count
  stall_count="$(get_stall_count)"
  stall_count=$((stall_count + 1))
  set_stall_count "$stall_count"

  log "STALL DETECTED (count: $stall_count). State.json is stale."

  if [ "$stall_count" -ge "$MAX_STALLS" ]; then
    log "Max stalls reached. Spawning fresh Orchestrator."
    spawn_fresh_orchestrator
    write_status "recovered" "Spawned fresh Orchestrator after $stall_count stalls"
  else
    log "First stall. Sending relaunch to Orchestrator."
    send_relaunch_to_orchestrator
    write_status "relaunching" "Sent relaunch signal (stall $stall_count)"
  fi

  return 1  # continue watching
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry Points
# ─────────────────────────────────────────────────────────────────────────────

run_once() {
  ensure_dirs
  acquire_lock
  if run_check; then
    log "Pipeline complete. Watchdog exiting."
  else
    log "Check complete. Pipeline still running."
  fi
}

run_daemon() {
  ensure_dirs
  acquire_lock

  log "Watchdog starting (interval: ${INTERVAL}s, stall threshold: ${STALL_THRESHOLD}s)"
  write_status "running" "Watchdog started with interval ${INTERVAL}s"

  while true; do
    if run_check; then
      log "Pipeline complete. Watchdog exiting."
      break
    fi
    log "Sleeping ${INTERVAL}s until next check..."
    sleep "$INTERVAL"
  done
}

show_status() {
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    echo '{"status":"not_running","detail":"No watchdog status file found"}'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --once)
    run_once
    ;;
  --status)
    show_status
    ;;
  --help|-h)
    echo "Usage: $0 [interval_seconds] | --once | --status"
    echo ""
    echo "  interval_seconds  Watchdog check interval (default: 1200)"
    echo "  --once            Run a single check and exit"
    echo "  --status          Show current watchdog status"
    echo ""
    echo "Environment:"
    echo "  SUPERTEAM_DIR     State directory (default: .superteam)"
    ;;
  *)
    run_daemon
    ;;
esac
