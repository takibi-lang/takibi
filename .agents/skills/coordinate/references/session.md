# Shared session procedure

This is the same workflow for Claude Code and Codex. Natural-language requests
express the work; a client command such as `/goal` is only a runtime wrapper.
Use it only when available and explicitly requested. Never create a persistent
goal merely because the maintainer asked to resume a session.

## Start and resume

Before scheduling work, read `~/.takibi-sessions/handoff.md`, `ROADMAP.md`,
`DECISIONS.md`, and the audit and decision files named by the handoff. If no
handoff exists, say so and reconstruct from Git and issue comments. Verify
`git status`, `git log`, `git worktree list --porcelain`, and the relevant
issues: the handoff is a snapshot, not proof that its commits are landed or
its workers still live. Preserve dirty trees and unlanded branches.

Restore the issue/territory/worktree/branch table, outstanding verification,
audits and pending decisions. Resume with fresh workers using the runtime
adapter. Do not start a duplicate worker for work another live session owns.
Pending decisions remain pending across runtime changes.

When asked to keep taking both queues, continue eligible ROADMAP issues with
at most one active worker per territory. An issue blocked on a decision does
not block unrelated eligible issues. Respect dependencies and existing scope
and land gates. When no eligible work remains, report the blockers and wait;
do not invent work or repeatedly poll without a purpose.

## Maintainer away

Enter away mode only on an explicit request. Pause the affected issue when a
maintainer decision is needed, preserving its branch, progress, next step
and partial audit. Continue other eligible issues, including another issue
in that territory after its previous worker is paused. Never infer approval
from absence or elapsed time, and do not land an escalated branch.

Consolidate newly needed decisions into one Japanese Markdown file for the
away period, `~/.takibi-sessions/decisions/<YYYY-MM-DD>.md`. Reuse that file
for the period; if the date's existing file belongs to another period or
session, choose a unique suffix. Preserve prior contents. Record for each:

- Issue, territory, branch, worktree and relevant audit.
- The exact question, evidence, options with costs, and recommendation.
- What is blocked, what can proceed independently, and decision status.

The coordinator writes decisions; workers report them to the coordinator.
Do not write into a repository-local `.takibi-sessions/` by accident. The
canonical session directory is `~/.takibi-sessions/`; resolve shorthand in
conversation to that directory unless the maintainer explicitly chooses a
different location. Do not copy private session notes into tracked files.

## Maintainer returns

Switch back to interactive decision handling immediately when requested.
List the actual filenames containing unresolved decisions, with a brief
issue summary. Do not mark those decisions resolved merely because the
maintainer returned. Present new decisions in the prompt and wait for an
answer for the affected work. Record answers in the decision note and on the
relevant issue, and record durable principles in `DECISIONS.md` as required
by the coordinate procedure. Resume only the work those answers authorize.

## Close and handoff

Pause workers cooperatively. At each worker sub-session boundary require the
shared contract's audit and recurrence-prevention review, even for a partial
slice. Let any land finish; do not write tracked files during it.

On an explicit close/handoff request, write a Japanese
`~/.takibi-sessions/handoff.md` after reconciling the actual Git state. Include:

- Timestamp, checkout, agent runtime, main and origin/main hashes.
- Territory, issue, absolute worktree, branch and HEAD for every active or
  paused slice, plus whether any worker or command is still running.
- Uncommitted changes, unlanded commits, last verified HEAD, checks and
  failures, and exact next steps and already-tried dead ends.
- Audit filenames and review status; pending decision filenames and blockers.
- Away/interactive mode, the standing queue request, and publication status.

Preserve unresolved older entries while updating the snapshot; never erase
another live coordinator's handoff. The next session must verify the snapshot
again and must not rely on old worker IDs. Keep session notes outside Git;
tracked guidance and GitHub text remain English ASCII. No additional
end-of-session skill is needed.
