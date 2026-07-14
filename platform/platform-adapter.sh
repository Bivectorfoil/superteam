#!/bin/bash
# platform-adapter.sh - Platform abstraction layer for Superteam
#
# Provides unified API functions that map to platform-specific implementations.
# Detects the current platform and delegates to the appropriate backend.
#
# Usage: source platform/platform-adapter.sh
#
# Unified API:
#   platform_create_team <name>              - Create an agent team
#   platform_spawn_agent <name> <def_path>   - Spawn a teammate
#   platform_send_message <to> <body>        - Send message to teammate
#   platform_schedule_wakeup <seconds>       - Schedule watchdog timer
#   platform_kill_agent <name>               - Kill a teammate
#
# Environment:
#   SUPERTEAM_PLATFORM    Override platform detection (claude|codex|opencode|generic)
#   SUPERTEAM_TEAM_NAME   Current team name (set by platform_create_team)
#   SUPERTEAM_SIGNAL_DIR  Signal directory for generic backend (default: .superteam/signals)

set -euo pipefail

SUPERTEAM_SIGNAL_DIR="${SUPERTEAM_SIGNAL_DIR:-.superteam/signals}"

# ─────────────────────────────────────────────────────────────────────────────
# Platform Detection
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
  if [ -n "${SUPERTEAM_PLATFORM:-}" ]; then
    echo "$SUPERTEAM_PLATFORM"
    return
  fi

  # Claude Code: check for .claude directory with settings.json
  if [ -f ".claude/settings.json" ] && [ -d ".claude/skills" ]; then
    echo "claude"
    return
  fi

  # Codex: check for .codex directory with config.toml
  if [ -f ".codex/config.toml" ] && [ -d ".codex/agents" ]; then
    echo "codex"
    return
  fi

  # OpenCode: check for .opencode directory with package.json or agents
  if [ -d ".opencode/agents" ] && [ -d ".opencode/plugins" ]; then
    echo "opencode"
    return
  fi

  # Fallback
  echo "generic"
}

PLATFORM="$(detect_platform)"
export SUPERTEAM_PLATFORM="$PLATFORM"

# ─────────────────────────────────────────────────────────────────────────────
# Backend: Claude Code
# ─────────────────────────────────────────────────────────────────────────────

_claude_create_team() {
  local name="$1"
  export SUPERTEAM_TEAM_NAME="$name"
  # TeamCreate is a Claude Code native API - output as instruction for the TL agent
  cat <<EOF
[PLATFORM:claude] TeamCreate(name="$name")
EOF
}

_claude_spawn_agent() {
  local name="$1"
  local def_path="$2"
  local context="${3:-}"
  local isolation="${4:-}"
  local team="${SUPERTEAM_TEAM_NAME:-unknown}"
  # Agent with team_name is a Claude Code native API
  cat <<EOF
[PLATFORM:claude] Agent(team_name="$team", name="$name", agent_def="$def_path", isolation="$isolation")
CONTEXT: $context
EOF
}

_claude_send_message() {
  local to="$1"
  local body="$2"
  # SendMessage is a Claude Code native API
  cat <<EOF
[PLATFORM:claude] SendMessage(to="$to", body="$body")
EOF
}

_claude_schedule_wakeup() {
  local seconds="$1"
  local prompt="${2:-watchdog check}"
  # ScheduleWakeup is a Claude Code native API
  cat <<EOF
[PLATFORM:claude] ScheduleWakeup(delaySeconds=$seconds, prompt="$prompt")
EOF
}

_claude_kill_agent() {
  local name="$1"
  local reason="${2:-shutdown}"
  cat <<EOF
[PLATFORM:claude] SendMessage(to="$name", body='{"type":"shutdown_request","reason":"$reason"}')
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Backend: Codex
# ─────────────────────────────────────────────────────────────────────────────

_codex_create_team() {
  local name="$1"
  export SUPERTEAM_TEAM_NAME="$name"
  # Codex uses multi_agent_v2 - teams are implicit from the main session
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  echo "$name" > "$SUPERTEAM_SIGNAL_DIR/team-name"
  cat <<EOF
[PLATFORM:codex] Team "$name" created via signal file
EOF
}

_codex_spawn_agent() {
  local name="$1"
  local def_path="$2"
  local context="${3:-}"
  local isolation="${4:-}"
  # Codex uses spawn_agent / sub-agent dispatch
  # Write spawn signal for the Codex runtime
  local signal_file="$SUPERTEAM_SIGNAL_DIR/spawn-${name}.json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "spawn",
  "name": "$name",
  "agent_def": "$def_path",
  "context": $(echo "$context" | jq -Rs .),
  "isolation": "$isolation",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:codex] Agent "$name" spawn signal written to $signal_file
EOF
}

_codex_send_message() {
  local to="$1"
  local body="$2"
  # Codex: write message to signal file for target agent
  local signal_file="$SUPERTEAM_SIGNAL_DIR/msg-${to}-$(date +%s).json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "message",
  "to": "$to",
  "body": $(echo "$body" | jq -Rs .),
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:codex] Message to "$to" written to $signal_file
EOF
}

_codex_schedule_wakeup() {
  local seconds="$1"
  local prompt="${2:-watchdog check}"
  # Codex: use external timer (launchd/cron/background process)
  cat <<EOF
[PLATFORM:codex] ScheduleWakeup($seconds) - use external timer (cron/launchd)
  Run: nohup bash platform/watchdog-daemon.sh $seconds &
EOF
}

_codex_kill_agent() {
  local name="$1"
  local reason="${2:-shutdown}"
  local signal_file="$SUPERTEAM_SIGNAL_DIR/kill-${name}.json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "kill",
  "name": "$name",
  "reason": "$reason",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:codex] Kill signal for "$name" written to $signal_file
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Backend: OpenCode
# ─────────────────────────────────────────────────────────────────────────────

_opencode_create_team() {
  local name="$1"
  export SUPERTEAM_TEAM_NAME="$name"
  # OpenCode: teams are managed via plugin context
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  echo "$name" > "$SUPERTEAM_SIGNAL_DIR/team-name"
  cat <<EOF
[PLATFORM:opencode] Team "$name" created via plugin context
EOF
}

_opencode_spawn_agent() {
  local name="$1"
  local def_path="$2"
  local context="${3:-}"
  local isolation="${4:-}"
  # OpenCode: use Task tool or plugin dispatch
  local signal_file="$SUPERTEAM_SIGNAL_DIR/spawn-${name}.json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "spawn",
  "name": "$name",
  "agent_def": "$def_path",
  "context": $(echo "$context" | jq -Rs .),
  "isolation": "$isolation",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:opencode] Agent "$name" spawn signal written to $signal_file
EOF
}

_opencode_send_message() {
  local to="$1"
  local body="$2"
  # OpenCode: write message to signal file
  local signal_file="$SUPERTEAM_SIGNAL_DIR/msg-${to}-$(date +%s).json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "message",
  "to": "$to",
  "body": $(echo "$body" | jq -Rs .),
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:opencode] Message to "$to" written to $signal_file
EOF
}

_opencode_schedule_wakeup() {
  local seconds="$1"
  local prompt="${2:-watchdog check}"
  cat <<EOF
[PLATFORM:opencode] ScheduleWakeup($seconds) - use external timer
  Run: nohup bash platform/watchdog-daemon.sh $seconds &
EOF
}

_opencode_kill_agent() {
  local name="$1"
  local reason="${2:-shutdown}"
  local signal_file="$SUPERTEAM_SIGNAL_DIR/kill-${name}.json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "kill",
  "name": "$name",
  "reason": "$reason",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:opencode] Kill signal for "$name" written to $signal_file
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Backend: Generic (file signals + external scripts)
# ─────────────────────────────────────────────────────────────────────────────

_generic_create_team() {
  local name="$1"
  export SUPERTEAM_TEAM_NAME="$name"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  echo "$name" > "$SUPERTEAM_SIGNAL_DIR/team-name"
  cat <<EOF
[PLATFORM:generic] Team "$name" created via signal files in $SUPERTEAM_SIGNAL_DIR
EOF
}

_generic_spawn_agent() {
  local name="$1"
  local def_path="$2"
  local context="${3:-}"
  local isolation="${4:-}"
  local signal_file="$SUPERTEAM_SIGNAL_DIR/spawn-${name}.json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "spawn",
  "name": "$name",
  "agent_def": "$def_path",
  "context": $(echo "$context" | jq -Rs .),
  "isolation": "$isolation",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:generic] Agent "$name" spawn signal written to $signal_file
  External orchestrator must poll $SUPERTEAM_SIGNAL_DIR/ for spawn signals.
EOF
}

_generic_send_message() {
  local to="$1"
  local body="$2"
  local signal_file="$SUPERTEAM_SIGNAL_DIR/msg-${to}-$(date +%s).json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "message",
  "to": "$to",
  "body": $(echo "$body" | jq -Rs .),
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:generic] Message to "$to" written to $signal_file
EOF
}

_generic_schedule_wakeup() {
  local seconds="$1"
  local prompt="${2:-watchdog check}"
  cat <<EOF
[PLATFORM:generic] ScheduleWakeup($seconds) - use platform/watchdog-daemon.sh
  Run: nohup bash platform/watchdog-daemon.sh $seconds &
EOF
}

_generic_kill_agent() {
  local name="$1"
  local reason="${2:-shutdown}"
  local signal_file="$SUPERTEAM_SIGNAL_DIR/kill-${name}.json"
  mkdir -p "$SUPERTEAM_SIGNAL_DIR"
  cat > "$signal_file" <<SIGNAL
{
  "action": "kill",
  "name": "$name",
  "reason": "$reason",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
SIGNAL
  cat <<EOF
[PLATFORM:generic] Kill signal for "$name" written to $signal_file
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Unified API (dispatches to platform backend)
# ─────────────────────────────────────────────────────────────────────────────

platform_create_team() {
  local name="$1"
  case "$PLATFORM" in
    claude)   _claude_create_team "$name" ;;
    codex)    _codex_create_team "$name" ;;
    opencode) _opencode_create_team "$name" ;;
    generic)  _generic_create_team "$name" ;;
    *)        echo "Unknown platform: $PLATFORM" >&2; return 1 ;;
  esac
}

platform_spawn_agent() {
  local name="$1"
  local def_path="$2"
  local context="${3:-}"
  local isolation="${4:-}"
  case "$PLATFORM" in
    claude)   _claude_spawn_agent "$name" "$def_path" "$context" "$isolation" ;;
    codex)    _codex_spawn_agent "$name" "$def_path" "$context" "$isolation" ;;
    opencode) _opencode_spawn_agent "$name" "$def_path" "$context" "$isolation" ;;
    generic)  _generic_spawn_agent "$name" "$def_path" "$context" "$isolation" ;;
    *)        echo "Unknown platform: $PLATFORM" >&2; return 1 ;;
  esac
}

platform_send_message() {
  local to="$1"
  local body="$2"
  case "$PLATFORM" in
    claude)   _claude_send_message "$to" "$body" ;;
    codex)    _codex_send_message "$to" "$body" ;;
    opencode) _opencode_send_message "$to" "$body" ;;
    generic)  _generic_send_message "$to" "$body" ;;
    *)        echo "Unknown platform: $PLATFORM" >&2; return 1 ;;
  esac
}

platform_schedule_wakeup() {
  local seconds="$1"
  local prompt="${2:-watchdog check}"
  case "$PLATFORM" in
    claude)   _claude_schedule_wakeup "$seconds" "$prompt" ;;
    codex)    _codex_schedule_wakeup "$seconds" "$prompt" ;;
    opencode) _opencode_schedule_wakeup "$seconds" "$prompt" ;;
    generic)  _generic_schedule_wakeup "$seconds" "$prompt" ;;
    *)        echo "Unknown platform: $PLATFORM" >&2; return 1 ;;
  esac
}

platform_kill_agent() {
  local name="$1"
  local reason="${2:-shutdown}"
  case "$PLATFORM" in
    claude)   _claude_kill_agent "$name" "$reason" ;;
    codex)    _codex_kill_agent "$name" "$reason" ;;
    opencode) _opencode_kill_agent "$name" "$reason" ;;
    generic)  _generic_kill_agent "$name" "$reason" ;;
    *)        echo "Unknown platform: $PLATFORM" >&2; return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Utility
# ─────────────────────────────────────────────────────────────────────────────

platform_info() {
  cat <<EOF
Platform: $PLATFORM
Team Name: ${SUPERTEAM_TEAM_NAME:-<not set>}
Signal Dir: $SUPERTEAM_SIGNAL_DIR
Available APIs: platform_create_team, platform_spawn_agent, platform_send_message, platform_schedule_wakeup, platform_kill_agent
EOF
}

# Source guard - prevent double sourcing
_SUPERTEAM_PLATFORM_ADAPTER_LOADED=1
