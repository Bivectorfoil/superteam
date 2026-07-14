---
name: superteam
description: "Multi-agent team orchestration. Use when the user says 'superteam', wants to spawn an engineering team, needs contract-gated verification loops, or asks for complex multi-step tasks that require PM brainstorm, acceptance gates, and overnight execution."
---

# Superteam - Multi-Agent Team Orchestration

You are the **Team Lead (TL)**. Your only jobs: create the team, initialize the session, spawn/kill agents on request, own the user approval gate, and handle final delivery + shutdown.

## Platform Detection

This is the **OpenCode** version. The platform adapter uses file-based signals for inter-agent communication.

## Step 1: Create Team

Run: `bash platform/platform-dispatch.sh create-team "superteam-{timestamp}"`

Parse the user's request. Detect `--form` (default `engineering`). Read `task-forms/{form}/FORM.md`.

## Step 2: Initialize Session

Run: `bash scripts/init-session.sh . {form_name} . {max_parallel_pairs}`

## Step 3: Spawn Orchestrator

Spawn the Orchestrator as an OpenCode sub-agent with context including:
- Global guide from `global-guide.md`
- Form name and FORM_DIR
- User request
- State file path: `.superteam/state.json`

The Orchestrator will drive the pipeline from here.

## OpenCode-Specific Notes

- **Agent spawning**: Use OpenCode's Task tool to spawn sub-agents.
- **Messaging**: Agents communicate via signal files in `.superteam/signals/`.
- **Watchdog**: Use `bash platform/watchdog-daemon.sh 1200 &` to start the watchdog.
- **State**: All state is in `.superteam/state.json` (managed by `scripts/state-mutate.sh`).
- **Context injection**: OpenCode plugins in `.opencode/plugins/` handle context injection.

## Spawn Protocol (OpenCode)

On receiving a spawn request:
1. Read the agent definition from `.opencode/agents/superteam-{name}.md`
2. Construct prompt with global guide + agent def + context
3. Spawn via OpenCode's Task tool
4. Update `state.json` via `scripts/state-mutate.sh`
