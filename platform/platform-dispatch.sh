#!/bin/bash
# platform-dispatch.sh - Helper for agents to call platform APIs via subprocess
#
# Agents cannot source platform-adapter.sh directly (they run in separate processes).
# This script provides a CLI interface to the platform adapter functions.
#
# Usage:
#   bash platform/platform-dispatch.sh create-team <name>
#   bash platform/platform-dispatch.sh spawn-agent <name> <def_path> [context] [isolation]
#   bash platform/platform-dispatch.sh send-message <to> <body>
#   bash platform/platform-dispatch.sh schedule-wakeup <seconds> [prompt]
#   bash platform/platform-dispatch.sh kill-agent <name> [reason]
#   bash platform/platform-dispatch.sh info
#   bash platform/platform-dispatch.sh detect

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/platform-adapter.sh"

case "${1:-}" in
  create-team)
    platform_create_team "${2:?name required}"
    ;;
  spawn-agent)
    platform_spawn_agent "${2:?name required}" "${3:?def_path required}" "${4:-}" "${5:-}"
    ;;
  send-message)
    platform_send_message "${2:?to required}" "${3:?body required}"
    ;;
  schedule-wakeup)
    platform_schedule_wakeup "${2:?seconds required}" "${3:-watchdog check}"
    ;;
  kill-agent)
    platform_kill_agent "${2:?name required}" "${3:-shutdown}"
    ;;
  info)
    platform_info
    ;;
  detect)
    echo "$PLATFORM"
    ;;
  *)
    echo "Usage: $0 {create-team|spawn-agent|send-message|schedule-wakeup|kill-agent|info|detect}" >&2
    exit 1
    ;;
esac
