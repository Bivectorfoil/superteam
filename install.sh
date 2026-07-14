#!/bin/bash
# install.sh - Unified installer for Superteam plugin
#
# Detects the current platform and installs superteam to the appropriate location.
#
# Usage:
#   bash install.sh              # Auto-detect platform and install
#   bash install.sh --platform <name>  # Force platform (claude|codex|opencode)
#   bash install.sh --list       # List supported platforms
#   bash install.sh --uninstall  # Remove superteam from current platform
#
# Environment:
#   SUPERTEAM_INSTALL_DIR  Override installation directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="superteam"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Platform Detection
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
  if [ -n "${SUPERTEAM_PLATFORM:-}" ]; then
    echo "$SUPERTEAM_PLATFORM"
    return
  fi
  if [ -f ".claude/settings.json" ] && [ -d ".claude/skills" ]; then
    echo "claude"
  elif [ -f ".codex/config.toml" ] && [ -d ".codex/agents" ]; then
    echo "codex"
  elif [ -d ".opencode/agents" ] && [ -d ".opencode/plugins" ]; then
    echo "opencode"
  else
    echo "generic"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Install Functions
# ─────────────────────────────────────────────────────────────────────────────

install_claude() {
  local target_dir="${SUPERTEAM_INSTALL_DIR:-.claude}"
  info "Installing superteam for Claude Code → $target_dir/"

  # Skills
  mkdir -p "$target_dir/skills/superteam"
  cp -r "$SCRIPT_DIR/skills/superteam/"* "$target_dir/skills/superteam/" 2>/dev/null || true
  ok "Skills installed"

  # Agents
  mkdir -p "$target_dir/agents"
  for agent in "$SCRIPT_DIR/agents/"*.md; do
    [ -f "$agent" ] && cp "$agent" "$target_dir/agents/"
  done
  ok "Agents installed"

  # Hooks
  mkdir -p "$target_dir/hooks"
  for hook in "$SCRIPT_DIR/hooks/"*.sh "$SCRIPT_DIR/hooks/"*.py; do
    [ -f "$hook" ] && cp "$hook" "$target_dir/hooks/"
  done
  [ -f "$SCRIPT_DIR/hooks/hooks.json" ] && cp "$SCRIPT_DIR/hooks/hooks.json" "$target_dir/hooks/"
  ok "Hooks installed"

  # Settings (merge with existing)
  if [ -f "$target_dir/settings.json" ]; then
    info "Existing settings.json found - hooks will be configured manually"
  else
    cp "$SCRIPT_DIR/.claude/settings.json" "$target_dir/settings.json"
    ok "Settings installed"
  fi

  # Scripts (symlink to keep in sync)
  ln -sfn "$SCRIPT_DIR/scripts" "$target_dir/superteam-scripts"
  ok "Scripts linked"

  # Task forms
  ln -sfn "$SCRIPT_DIR/task-forms" "$target_dir/superteam-task-forms"
  ok "Task forms linked"

  # Global guide
  cp "$SCRIPT_DIR/global-guide.md" "$target_dir/superteam-global-guide.md"
  ok "Global guide installed"

  echo ""
  ok "Superteam installed for Claude Code!"
  info "Usage: /superteam <your request>"
}

install_codex() {
  local target_dir="${SUPERTEAM_INSTALL_DIR:-.codex}"
  info "Installing superteam for Codex → $target_dir/"

  # Config (required for platform detection)
  if [ -f "$target_dir/config.toml" ]; then
    info "Existing config.toml found - skipping"
  else
    [ -f "$SCRIPT_DIR/.codex/config.toml" ] && cp "$SCRIPT_DIR/.codex/config.toml" "$target_dir/config.toml"
    ok "Config installed"
  fi

  # Agents - convert .md to .toml format
  mkdir -p "$target_dir/agents"
  for agent in "$SCRIPT_DIR/agents/"*.md; do
    [ -f "$agent" ] || continue
    local name
    name="$(basename "$agent" .md)"
    # Copy as .md (Codex can read markdown agent defs)
    cp "$agent" "$target_dir/agents/${name}.md"
  done
  ok "Agents installed"

  # Plugin config
  [ -f "$SCRIPT_DIR/.codex/plugin.toml" ] && cp "$SCRIPT_DIR/.codex/plugin.toml" "$target_dir/plugin.toml"
  ok "Plugin config installed"

  # Hooks
  mkdir -p "$target_dir/hooks"
  for hook in "$SCRIPT_DIR/hooks/"*.sh "$SCRIPT_DIR/hooks/"*.py; do
    [ -f "$hook" ] && cp "$hook" "$target_dir/hooks/"
  done
  [ -f "$SCRIPT_DIR/.codex/hooks.json" ] && cp "$SCRIPT_DIR/.codex/hooks.json" "$target_dir/hooks.json"
  ok "Hooks installed"

  # Skills (shared .agents/skills/)
  mkdir -p ".agents/skills/superteam"
  cp -r "$SCRIPT_DIR/skills/superteam/"* ".agents/skills/superteam/" 2>/dev/null || true
  ok "Skills installed to .agents/skills/"

  # Scripts
  ln -sfn "$SCRIPT_DIR/scripts" "$target_dir/superteam-scripts"
  ok "Scripts linked"

  # Task forms
  ln -sfn "$SCRIPT_DIR/task-forms" "$target_dir/superteam-task-forms"
  ok "Task forms linked"

  # Global guide
  cp "$SCRIPT_DIR/global-guide.md" "$target_dir/superteam-global-guide.md"
  ok "Global guide installed"

  echo ""
  ok "Superteam installed for Codex!"
  info "Usage: Describe your task in Codex (e.g. 'use superteam to build a Redis queue')"
}

install_opencode() {
  local target_dir="${SUPERTEAM_INSTALL_DIR:-.opencode}"
  info "Installing superteam for OpenCode → $target_dir/"

  # Agents
  mkdir -p "$target_dir/agents"
  for agent in "$SCRIPT_DIR/agents/"*.md; do
    [ -f "$agent" ] || continue
    cp "$agent" "$target_dir/agents/"
  done
  ok "Agents installed"

  # Plugin config
  [ -f "$SCRIPT_DIR/.opencode/plugin.json" ] && cp "$SCRIPT_DIR/.opencode/plugin.json" "$target_dir/plugin.json"
  ok "Plugin config installed"

  # Skills
  mkdir -p "$target_dir/skills/superteam"
  cp -r "$SCRIPT_DIR/skills/superteam/"* "$target_dir/skills/superteam/" 2>/dev/null || true
  ok "Skills installed"

  # Plugins (JS)
  mkdir -p "$target_dir/plugins"
  for plugin in "$SCRIPT_DIR/.opencode/plugins/"*.js; do
    [ -f "$plugin" ] && cp "$plugin" "$target_dir/plugins/"
  done
  ok "Plugins installed"

  # Lib
  mkdir -p "$target_dir/lib"
  for lib in "$SCRIPT_DIR/.opencode/lib/"*.js; do
    [ -f "$lib" ] && cp "$lib" "$target_dir/lib/"
  done
  ok "Lib installed"

  # Hooks
  mkdir -p "$target_dir/hooks"
  for hook in "$SCRIPT_DIR/hooks/"*.sh "$SCRIPT_DIR/hooks/"*.py; do
    [ -f "$hook" ] && cp "$hook" "$target_dir/hooks/"
  done
  ok "Hooks installed"

  # Scripts
  ln -sfn "$SCRIPT_DIR/scripts" "$target_dir/superteam-scripts"
  ok "Scripts linked"

  # Task forms
  ln -sfn "$SCRIPT_DIR/task-forms" "$target_dir/superteam-task-forms"
  ok "Task forms linked"

  # Global guide
  cp "$SCRIPT_DIR/global-guide.md" "$target_dir/superteam-global-guide.md"
  ok "Global guide installed"

  # opencode.json - register skills path
  if [ -f "opencode.json" ]; then
    # Existing config - try to merge skills.paths
    if command -v jq &>/dev/null; then
      # Backup before modifying
      cp opencode.json opencode.json.bak
      local merged
      merged=$(jq '.skills = (.skills // {}) | .skills.paths = ((.skills.paths // []) + [".opencode/skills"] | unique)' opencode.json 2>/dev/null)
      if [ -n "$merged" ] && echo "$merged" | jq empty 2>/dev/null; then
        echo "$merged" > opencode.json
        rm -f opencode.json.bak
        ok "Updated opencode.json with skills path"
      else
        # Restore backup on failure
        mv opencode.json.bak opencode.json
        warn "Could not merge opencode.json - please add '.opencode/skills' to skills.paths manually"
      fi
    else
      warn "opencode.json exists but jq not installed - please add '.opencode/skills' to skills.paths manually"
    fi
  else
    # Create new config
    cat > opencode.json <<'CONFIG'
{
  "$schema": "https://opencode.ai/config.json",
  "skills": {
    "paths": [".opencode/skills"]
  }
}
CONFIG
    ok "Created opencode.json"
  fi

  echo ""
  ok "Superteam installed for OpenCode!"
  info "Usage: Describe your task in OpenCode (e.g. 'use superteam to build a Redis queue')"
  info "Note: Restart OpenCode for the skill to take effect"
}

install_generic() {
  local target_dir="${SUPERTEAM_INSTALL_DIR:-.superteam-install}"
  info "Installing superteam (generic) → $target_dir/"

  mkdir -p "$target_dir"
  cp -r "$SCRIPT_DIR/agents" "$target_dir/"
  cp -r "$SCRIPT_DIR/scripts" "$target_dir/"
  cp -r "$SCRIPT_DIR/hooks" "$target_dir/"
  cp -r "$SCRIPT_DIR/skills" "$target_dir/"
  cp -r "$SCRIPT_DIR/task-forms" "$target_dir/"
  cp -r "$SCRIPT_DIR/platform" "$target_dir/"
  cp "$SCRIPT_DIR/global-guide.md" "$target_dir/"
  ok "All files installed"

  echo ""
  ok "Superteam installed (generic)!"
  info "Usage: source $target_dir/platform/platform-adapter.sh"
  info "Platform adapter will use file-based signals in .superteam/signals/"
}

# ─────────────────────────────────────────────────────────────────────────────
# Uninstall
# ─────────────────────────────────────────────────────────────────────────────

uninstall() {
  local platform
  platform="$(detect_platform)"
  local target_dir

  case "$platform" in
    claude)   target_dir="${SUPERTEAM_INSTALL_DIR:-.claude}" ;;
    codex)    target_dir="${SUPERTEAM_INSTALL_DIR:-.codex}" ;;
    opencode) target_dir="${SUPERTEAM_INSTALL_DIR:-.opencode}" ;;
    generic)  target_dir="${SUPERTEAM_INSTALL_DIR:-.superteam-install}" ;;
    *)        error "Unknown platform: $platform"; exit 1 ;;
  esac

  info "Uninstalling superteam from $target_dir/"

  # Remove superteam-specific files
  rm -rf "$target_dir/skills/superteam" 2>/dev/null || true
  rm -rf "$target_dir/agents/orchestrator.md" 2>/dev/null || true
  rm -rf "$target_dir/agents/manager.md" 2>/dev/null || true
  rm -rf "$target_dir/agents/pm.md" 2>/dev/null || true
  rm -rf "$target_dir/agents/architect.md" 2>/dev/null || true
  rm -rf "$target_dir/agents/explorer.md" 2>/dev/null || true
  rm -rf "$target_dir/agents/plan-evaluator.md" 2>/dev/null || true
  rm -rf "$target_dir/agents/curator.md" 2>/dev/null || true
  rm -f "$target_dir/superteam-scripts" 2>/dev/null || true
  rm -f "$target_dir/superteam-task-forms" 2>/dev/null || true
  rm -f "$target_dir/superteam-global-guide.md" 2>/dev/null || true
  rm -f "$target_dir/plugin.toml" 2>/dev/null || true
  rm -f "$target_dir/plugin.json" 2>/dev/null || true

  ok "Superteam uninstalled from $platform"
}

# ─────────────────────────────────────────────────────────────────────────────
# List
# ─────────────────────────────────────────────────────────────────────────────

list_platforms() {
  echo "Supported platforms:"
  echo ""
  echo "  claude    - Claude Code (native TeamCreate/Agent/SendMessage)"
  echo "  codex     - OpenAI Codex (multi_agent_v2 / spawn_agent)"
  echo "  opencode  - OpenCode (Task tool / plugin system)"
  echo "  generic   - Generic (file signals + external scripts)"
  echo ""
  echo "Current detected: $(detect_platform)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
  local platform=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --platform)  platform="$2"; shift 2 ;;
      --list)      list_platforms; exit 0 ;;
      --uninstall) uninstall; exit 0 ;;
      --help|-h)   echo "Usage: $0 [--platform <name>] [--list] [--uninstall]"; exit 0 ;;
      *)           error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [ -n "$platform" ]; then
    export SUPERTEAM_PLATFORM="$platform"
  fi

  local detected
  detected="$(detect_platform)"
  info "Detected platform: $detected"

  case "$detected" in
    claude)   install_claude ;;
    codex)    install_codex ;;
    opencode) install_opencode ;;
    generic)  install_generic ;;
    *)        error "Unknown platform: $detected"; exit 1 ;;
  esac
}

main "$@"
