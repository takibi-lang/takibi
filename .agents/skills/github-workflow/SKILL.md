---
name: github-workflow
description: Apply the Takibi Git and GitHub workflow when creating or updating an issue, recording a design decision, preparing a commit that closes an issue, choosing a Found-by value, or finishing work that must be committed. Use for gh issue operations and issue-closing commits. Never push or merge.
---

# Takibi Git and GitHub workflow

## Authority boundary

Agents stage and commit completed work locally. Never run `git push`, merge a
remote branch, or otherwise publish commits; the human maintainer owns that
gate. A skill does not expand tool permissions or user authorization.

Use `gh` for every GitHub operation. Do not use GitHub connectors, MCP tools,
or browser automation. If `gh` is unavailable or unauthenticated, complete the
local work and report the external step that remains.

## GitHub text

Issue titles, bodies, and comments must use English ASCII text. Every issue
must contain a `Found-by:` field. Record a settled design decision, tradeoff,
or root-cause conclusion on the relevant existing issue when one can be
identified from current context; do not guess an issue or open one unprompted.

Do not put live project status such as "tracked in" or "completed by" issue
references in tracked documentation or source comments. Current text must be
correct without GitHub access. `HISTORY.md` may record stable past events and
`ROADMAP.md` may enumerate the dated plan. A settled issue may be named in a
source comment only when it genuinely explains an enduring design rationale.

## Found-by

Choose the discovery channel, optionally followed by concise free text:

- `type-error`: the Takibi type checker rejected the program.
- `compiler-lint`: a compiler lint or build-check script reported it.
- `runtime-check`: a compiler-emitted check or kernel assertion fired.
- `test`: a unit, QEMU, integration, or hardware test failed.
- `qemu`: investigation under QEMU exposed it.
- `hardware`: real-board bring-up, SWD, or hardware measurement exposed it.
- `review`: code reading, audit, or maintainer report exposed it.
- `design`: design, research, or refactoring work rather than a defect.

An issue-closing commit requires a `Found-by:` trailer. Also add the trailer
for a defect found and fixed within one session even when no issue exists.

## Commit

Commit at a natural completed unit without waiting to be asked. Preserve
unrelated user changes and stage only the task's files. Use the identity for
the agent making the commit, applied only to that invocation:

- Codex: `OpenAI Codex <codex-agent@takibi.invalid>`
- Claude Code: `Anthropic Claude Code <claude-code-agent@takibi.invalid>`
- GitHub Copilot CLI: `GitHub Copilot CLI <copilot-cli-agent@takibi.invalid>`

Set author and committer environment variables on `git commit`; never change
repository or global `user.name` or `user.email`. After committing, report the
commit hash and verification performed, and do not push.
