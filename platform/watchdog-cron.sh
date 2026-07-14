#!/bin/bash
# watchdog-cron.sh - Cron-based watchdog for Superteam pipeline
#
# Install as a cron job to monitor pipeline health without a persistent daemon.
#
# Usage:
#   # Install (runs every 20 minutes):
#   crontab -l 2>/dev/null | { cat; echo "*/20 * * * * /bin/bash $(pwd)/platform/watchdog-cron.sh"; } | crontab -
#
#   # Uninstall:
#   crontab -l 2>/dev/null | grep -v "watchdog-cron.sh" | crontab -
#
#   # Manual run:
#   bash platform/watchdog-cron.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPERTEAM_DIR="${SUPERTEAM_DIR:-.superteam}"
LOG_FILE="$SUPERTEAM_DIR/watchdog-cron.log"

# Ensure log directory exists
mkdir -p "$SUPERTEAM_DIR"

# Log with timestamp
log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

# Run the watchdog daemon in --once mode
log "Cron watchdog check starting"
if bash "$SCRIPT_DIR/watchdog-daemon.sh" --once >> "$LOG_FILE" 2>&1; then
  log "Pipeline complete"
else
  log "Check complete, pipeline still running"
fi
