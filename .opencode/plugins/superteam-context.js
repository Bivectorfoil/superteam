/**
 * Superteam OpenCode Plugin
 *
 * Handles context injection for superteam agents.
 * Reads state from .superteam/state.json and injects relevant context
 * into agent prompts.
 */

import { existsSync, readFileSync } from "fs"
import { join } from "path"
import { execSync } from "child_process"

const SUPERTEAM_DIR = ".superteam"
const STATE_FILE = join(SUPERTEAM_DIR, "state.json")
const SIGNALS_DIR = join(SUPERTEAM_DIR, "signals")

/**
 * Read superteam state
 */
function readState() {
  if (!existsSync(STATE_FILE)) return null
  try {
    return JSON.parse(readFileSync(STATE_FILE, "utf-8"))
  } catch {
    return null
  }
}

/**
 * Read pending messages for an agent
 */
function readMessages(agentName) {
  if (!existsSync(SIGNALS_DIR)) return []
  try {
    const files = execSync(`ls -t ${SIGNALS_DIR}/msg-${agentName}-*.json 2>/dev/null || true`, {
      encoding: "utf-8"
    }).trim().split("\n").filter(Boolean)

    return files.map(f => {
      try {
        const data = JSON.parse(readFileSync(f, "utf-8"))
        return { file: f, ...data }
      } catch {
        return null
      }
    }).filter(Boolean)
  } catch {
    return []
  }
}

/**
 * Read spawn signals
 */
function readSpawnSignals() {
  if (!existsSync(SIGNALS_DIR)) return []
  try {
    const files = execSync(`ls -t ${SIGNALS_DIR}/spawn-*.json 2>/dev/null || true`, {
      encoding: "utf-8"
    }).trim().split("\n").filter(Boolean)

    return files.map(f => {
      try {
        return JSON.parse(readFileSync(f, "utf-8"))
      } catch {
        return null
      }
    }).filter(Boolean)
  } catch {
    return []
  }
}

/**
 * Plugin hook: inject superteam context into agent prompts
 */
export function onChatMessage(input) {
  const state = readState()
  if (!state) return input

  // Inject state summary into context
  const stateSummary = [
    `## Superteam State`,
    `- Phase: ${state.phase || "unknown"}`,
    `- Phase Step: ${state.phase_step || "unknown"}`,
    `- Active Agents: ${(state.agents?.active_agents || []).join(", ") || "none"}`,
    `- Session Started: ${state.session?.started || "unknown"}`,
  ].join("\n")

  return {
    ...input,
    context: `${input.context || ""}\n\n${stateSummary}`
  }
}

export default {
  onChatMessage
}
