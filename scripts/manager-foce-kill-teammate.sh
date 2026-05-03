#!/bin/bash
# manager-force-kill-teammate.sh - Belt-and-suspenders kill for a teammate.
#
# Manager kill flow (replaces the old TeammateIdle hook + TL-mediated kill):
#   1. Manager sends `{"type":"shutdown_request","request_id":"<uuid>","reason":"..."}`
#      to the target via SendMessage. If the target is responsive, it replies
#      with shutdown_response{approve:true} and Claude Code terminates its
#      process (cooperative path).
#   2. After a grace period (recommended: 60s, one Manager wakeup), Manager
#      runs THIS script. If the target is still listed in
#      .agents.active_agents, we assume the cooperative shutdown failed
#      (target hung, blocked on tool, or rejected) and force-kill its tmux
#      pane, then prune state.
#
# Usage:
#   bash scripts/manager-force-kill-teammate.sh <teammate_name>
#
# Exit codes:
#   0 - target was already gone, or kill+prune succeeded
#   1 - usage error or unrecoverable error (state.json missing, etc.)
#   2 - target listed as active but no tmux pane found (cannot force-kill;
#       Manager should escalate to user via Orchestrator)

set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 <teammate_name>" >&2
  exit 1
fi

SUPERTEAM_DIR="${SUPERTEAM_DIR:-.superteam}"
STATE_JSON="$SUPERTEAM_DIR/state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$STATE_JSON" ]; then
  echo "ERROR: $STATE_JSON not found" >&2
  exit 1
fi

# Step 1: Is the target still listed as active? If the cooperative
# shutdown_request worked, the harness should have already pruned them.
STILL_ACTIVE=$(jq -r --arg t "$TARGET" \
  '[.agents.active_agents[]? | select(.name == $t)] | length' \
  "$STATE_JSON" 2>/dev/null || echo "0")

if [ "$STILL_ACTIVE" = "0" ]; then
  echo "OK: '$TARGET' is no longer in .agents.active_agents (cooperative shutdown succeeded)." >&2
  exit 0
fi

echo "WARN: '$TARGET' still active after grace period - forcing kill via tmux." >&2

# Step 2: Locate the target's tmux pane. Claude Code's --teammate-mode tmux
# convention sets the pane title (and typically window name) to the
# teammate's name. Match on pane_title first, then fall back to window_name.
PANE_ID=""
if command -v tmux >/dev/null 2>&1; then
  PANE_ID=$(tmux list-panes -a -F "#{pane_id}|#{pane_title}" 2>/dev/null \
    | awk -F'|' -v t="$TARGET" '$2 == t {print $1; exit}')
  if [ -z "$PANE_ID" ]; then
    PANE_ID=$(tmux list-panes -a -F "#{pane_id}|#{window_name}" 2>/dev/null \
      | awk -F'|' -v t="$TARGET" '$2 == t {print $1; exit}')
  fi
fi

if [ -z "$PANE_ID" ]; then
  echo "ERROR: Could not locate tmux pane for '$TARGET' (no pane_title or window_name match). Manual intervention required." >&2
  exit 2
fi

# Step 3: Force-kill the pane.
if tmux kill-pane -t "$PANE_ID" 2>/dev/null; then
  echo "Killed tmux pane $PANE_ID (teammate=$TARGET)." >&2
else
  echo "ERROR: 'tmux kill-pane -t $PANE_ID' failed." >&2
  exit 2
fi

# Step 4: Prune from .agents.active_agents (CAS-protected).
new_agents=$(bash "$SCRIPT_DIR/state-mutate.sh" get .agents \
  | jq --arg t "$TARGET" '.active_agents |= map(select(.name != $t))')
bash "$SCRIPT_DIR/state-mutate.sh" --set agents="$new_agents"
echo "Pruned '$TARGET' from .agents.active_agents." >&2

exit 0
