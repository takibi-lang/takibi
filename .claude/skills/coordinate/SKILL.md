---
name: coordinate
description: Run Takibi's Territory A/B queues from one Claude Code session as coordinator -- spawn one territory-worker subagent per issue in its own git worktree, relay decisions and audits to the maintainer, land finished branches one at a time, and pause or restart cleanly. Use when the maintainer asks this session to coordinate, start, resume, pause, or land worker issues.
---

# Coordinate worktree workers

The canonical cross-agent skill is
`.agents/skills/coordinate/SKILL.md`. Read that file completely before acting
and follow it.
