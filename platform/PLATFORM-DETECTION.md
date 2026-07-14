# Platform Detection and Configuration
#
# This file documents the platform detection logic used by platform-adapter.sh.
# Override detection by setting SUPERTEAM_PLATFORM environment variable.

# Detection order:
# 1. SUPERTEAM_PLATFORM env var (explicit override)
# 2. .claude/settings.json + .claude/skills/ → claude
# 3. .codex/config.toml + .codex/agents/ → codex
# 4. .opencode/agents/ + .opencode/plugins/ → opencode
# 5. Fallback → generic

# Platform capabilities matrix:
#
# | Capability          | claude | codex | opencode | generic |
# |---------------------|--------|-------|----------|---------|
# | TeamCreate          | native | signal| signal   | signal  |
# | Agent spawn         | native | signal| signal   | signal  |
# | SendMessage         | native | signal| signal   | signal  |
# | ScheduleWakeup      | native | ext   | ext      | ext     |
# | Worktree isolation  | native | -     | -        | -       |
# | Hook injection      | native | native| native   | -       |
#
# native = platform API call
# signal = file-based signal in .superteam/signals/
# ext    = external script (watchdog-daemon.sh, cron, launchd)
# -      = not supported

# Signal file format (JSON):
# {
#   "action": "spawn|message|kill",
#   "name": "agent-name",
#   "to": "target-agent",        (for messages)
#   "body": "message content",   (for messages)
#   "agent_def": "path/to/def",  (for spawn)
#   "context": "spawn context",  (for spawn)
#   "reason": "kill reason",     (for kill)
#   "timestamp": "ISO-8601"
# }
