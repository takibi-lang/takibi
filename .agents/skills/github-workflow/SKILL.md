---
name: github-workflow
description: Apply the Takibi Git and GitHub workflow when creating or updating an issue, recording a design decision, preparing a commit that closes an issue, choosing a Found-by value, or finishing work that must be committed. Use for gh issue operations and issue-closing commits. Never push or merge.
---

# Takibi Git and GitHub workflow

## Authority boundary

Agents stage and commit completed work locally. Never run `git push`, merge a
remote branch, or otherwise publish commits; the human maintainer owns that
gate. A skill does not expand tool permissions or user authorization.

Integrating is not publishing: `git fetch` and `git rebase` onto the upstream
`main` are the agent's own to run, and AGENTS.md asks for them before an issue
is started and after each commit. Rebasing local commits that were never
pushed rewrites nothing anyone else holds.

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

## Shape an issue so it can close

Split work that decomposes into pieces with different dependency chains or
different investigation types into separate issues, each with a narrow,
concretely checkable acceptance condition, and cross-reference the siblings.
A bundled issue's closing bar drifts upward as sub-pieces are discovered, which
is how issues stay open for months.

When a closing-bar demonstration turns out to need a genuinely separate, larger
capability, stop and ask whether to build it here or split it out. Do not
silently expand the issue's scope, and do not silently declare victory on a
weakened bar.

Any "reopen this if X" sentence written into a recommendation is owed before
the close, not after. Naming a condition and not testing it produces a record
that reads as authoritative while saying "no evidence" about evidence that was
one search away.

## Re-verify an issue's premises before building on it

An issue body describes the tree at the moment it was written. Before
implementing, re-derive every number, constant, symbol, and file it depends on
against the current tree. Acting directly on a stale body produces work against
a codebase that no longer exists, and the wrong conclusion looks perfectly
reasoned. Put the corrected table in the closing comment; it is often most of
the value. The re-verification itself tends to find things.

Check who owns an area before adding a capability to a shared file. A question
that needs some capability does not make that capability yours to build, and
another agent may already own it with an order that matters. What is always
safe to keep is the finding, and tests for work already merged.

## Report only what a tool call returned

An issue number, URL, or identifier reported to the maintainer must come from
the return value of the call that created it, never from predicting the next
sequential number. When a discussion covers several issues and only some were
actually created, say plainly which ones were not. Re-check with a read-only
call before repeating a claim about an action taken earlier in a session.

## Hand off by writing, not by staying in one session

A long session does not buy atomicity; work large enough to worry about will
compact regardless. The choice is only where the boundary falls, and a boundary
where all state is externalised is far cheaper than one in the middle of a
half-finished migration. Before a natural break, write the residual unwritten
knowledge into the tracking issue as a plan meant to be read cold: which call
sites are mechanical and which are tricky, which idea makes the work cheap,
which numbers were measured, and which traps have already been paid for.

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
