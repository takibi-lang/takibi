---
name: coordinate
description: Run Takibi's Territory A/B queues from one coding-agent session as coordinator -- spawn one territory-worker subagent per issue in its own git worktree, relay decisions and audits to the maintainer, land finished branches one at a time, and pause or restart cleanly. Use when the maintainer asks this session to coordinate, start, resume, pause, or land worker issues.
---

# Coordinate worktree workers

Decided on GitHub issue #753 (maintainer, 2026-10-11). The coordinator is one
interactive coding-agent session (Claude Code or Codex). It stays free for the maintainer's own
questions; the issue work happens in background subagents. The maintainer
takes part in options -> discussion -> decision, and in any land that meets
an escalation condition; since 2026-10-18 the coordinator lands the rest
itself after checking the end-of-issue audit, and reports afterwards.
The coordinator decides what `DECISIONS.md` "Coordinator defaults" covers
and escalates the rest (exception-based gate, #753, 2026-10-16).

Talk to the maintainer in Japanese. Everything written to Git or GitHub stays
English ASCII.

## Session lifecycle

Read [the session procedure](references/session.md) on start, resume,
away/return instructions, and close. It defines the shared handoff and decision
files. A request to edit this workflow does not start the A/B queues or resume
the work recorded in a handoff. Start queue work only when requested.

## 1. Start a worker

1. Pick the next issue from `ROADMAP.md` for the territory, skipping issues
   that wait on a maintainer decision. Run at most one worker per territory
   (two in total) until the maintainer says otherwise. Territory A works
   the pillar (multicore, memory safety) issues that come as chains of
   dependent issues, like the #637 family; B takes pillar issues that can
   be solved independently and those slightly off the pillars. An urgent issue met mid-work is
   yours to schedule: rewrite ROADMAP.md priorities, record one line on the
   issue, and tell the maintainer afterwards in one line.
2. Choose the audit batch file: `~/.takibi-sessions/audits/<YYYY-MM-DD>_<issues>.md`,
   reusing the open batch until it is presented.
3. Read [the runtime adapter](references/runtime.md) for the current agent.
   Start a worker in its own worktree and require it to read
   [the shared worker contract](references/territory-worker.md) completely.
   Give the issue number, territory, absolute worktree path, branch, audit
   file, and any resume note. Record issue -> agent -> worktree -> branch
   in the conversation. Never rely on a named Claude agent being available
   in another runtime.

Nothing else is needed for isolation. Each worktree claims its own QEMU port
block automatically (`scripts/qemu_session_ports.sh` names it after the
worktree), and every QEMU guest leases vCPUs from the host-wide budget
(`scripts/vcpu_lease.sh`), so concurrent lanes wait rather than collide.

## 2. Relay

- A worker returns `needs decision`: show the options to the maintainer,
  translated faithfully, with the worker's recommendation. After the
  decision, record it on the issue (`github-workflow`) and as one line in
  `DECISIONS.md` (mark a replaced line superseded), and continue the same
  worker with the runtime message tool, so its context is kept.
- Maintainer advice for a running worker ("read the application-side
  source", ...): send it verbatim with the runtime message tool.
- Visibility: you do not see a worker's tool output. Check progress through
  its worktree (`git -C <worktree> log --oneline main..HEAD`, `git -C
  <worktree> status`, build logs under its `_build/`), or ask it for status
  with the runtime message tool.
- Stuck detection, coordinator side: when you check in (at every maintainer
  turn and every worker report), look at each running worker's time since
  its last commit and repeated failures in its logs; if one looks stuck for
  more than about an hour, tell the maintainer.

## 3. Land, in small batches

Decided 2026-11-07 (maintainer): when several finished branches wait,
stack them on origin/main in one temporary worktree and land them together
(one `scripts/land.sh` run). Branches whose kernels stay byte-identical
(scripts, docs, compiler-only) go four or five to a batch; branches that
change kernel code go two or three at most, or alone. Append-only conflicts
(ROADMAP, DECISIONS, table rows, test-list appends) are resolved by keeping
both sides; the trust ledger and space checkpoint are re-recorded once at
the top of the batch. On a red batch, decide intermittent vs real; for a
real failure, bisect by landing halves. Every branch keeps its own commits
and closing commit. Never run two lands at once.

Only the coordinator lands, from the main checkout (`scripts/land.sh`
refuses any branch but `main`).

1. The worker reported `done` and its audit is in the batch file.
   Every follow-up change requires an audit addendum naming the new HEAD
   and verification, and another audit-gate review. After a rebase, record
   the old/new HEAD mapping and inspect the diff; substantive resolutions
   need renewed review and approval for any escalated item.
2. **Audit gate (exception-based).** Read the full audit and check it
   against `DECISIONS.md`. Where a coordinator default applies, apply it
   yourself first: ask the worker (the runtime message tool) for the fix, test or filed
   issue, and record each call as one line on the issue. Then show the
   maintainer, in Japanese, only (a) the audit items that match an escalation
   condition (always including any language design change beyond surface
   syntax: semantics, type rules, ownership, capability or protocol model,
   accepted programs) or no default covers, plus any concern of your own, quoted
   verbatim from the audit, and (b) one line listing the defaults applied.
   If nothing escalates, say so in one line, land, and report the land.
   The full audit stays in the batch file; show it verbatim on request.
   Before landing, every remaining item in the audit carries an issue
   number; file each "unfiled" one yourself (`Found-by: review`), or ask
   the maintainer when filing needs a decision. Nothing remaining leaves
   the audit without a number or a YAGNI reason.
   Recurrence prevention is among the most important parts: check that
   each defect names its mechanism under AGENTS.md's lightweight prevention
   order, its real guarantee, and why stronger alternatives were not chosen;
   send it back if not.
   A branch with an escalated item lands only after the maintainer's
   approval; present it, then stop and wait for that branch.
3. **Land gates on the branch.** The space checkpoint is current
   (`python3 scripts/space_checkpoint.py --base origin/main --head <branch>` passes),
   and the ROADMAP.md update and issue-closing commit are on the branch.
   `scripts/land.sh` refuses a stale checkpoint before allcheck; #720, #719
   and #608 each cost a failed land round on it (2026-10-12). If a gate is
   missing, continue the worker with the runtime message tool to add it.
4. In the main checkout, clean and on `main`:
   `(cd <worktree> && python3 scripts/checkpoint_rebase.py --onto main)`,
   then `git merge --ff-only <branch>` for a single branch.
   For a batch, pause all contributing workers and require clean trees.
   Create unique temporary branch copies at each approved worker HEAD
   (`git branch <batch-copy> <worker-head>`), leaving the worker branches
   in their existing worktrees. Create a temporary integration worktree
   on another unique branch from origin/main. There run
   `python3 scripts/checkpoint_rebase.py --onto origin/main --stack <copy1> <copy2> ...`
   bottom-up (#1443). The copies must not be checked out elsewhere.
   After reviewing the resulting stack, return to the clean main checkout
   and `git merge --ff-only <top-copy>`. Do not use --ignore-other-worktrees
   or move an active worker's branch behind it. The helper resolves a conflict
   confined to `docs/SPACE_CHECKPOINT.json` by itself (#832: main's side,
   then the branch's own review re-recorded for the rebased head in a new
   commit), so that file no longer needs a round trip. Exit 2 means the
   branch's own review was not current: send it back. Exit 4 is a conflict
   in another file: resolve it yourself when it is mechanical, otherwise
   send it back to the worker.
5. Follow the `land` skill (`scripts/land.sh`). Never land two branches
   concurrently; never edit the tree while a land runs.
   On a red land, put main back to `origin/main` before sending the failure
   to the worker: `git switch -C main origin/main` (main is clean during a
   land, and the branch keeps its commits). Do not use `git reset --hard`;
   user and project settings deny it.
6. After a worker reports done and its work landed, run
   `make prune-worktrees WORKTREES=<worktree directory name>` (#1165;
   without `WORKTREES` it considers every worktree under .claude/worktrees).
   It unlocks and removes the worktree and deletes its branch only when the
   branch has no patch outside origin/main, the tree has no tracked changes,
   and no process has its cwd or an open file inside it, and prints what it
   kept and why. Not after a land alone: a worker may land one slice and go
   on in the same worktree. The port block needs no step: the next
   `qemu_session_claim_block` drops the row of a worktree that is gone, and a
   full registry takes over a block whose session has no lane running.
   Start a new batch only after every writer assigned to the old file
   acknowledges completion. Never rewrite or move sections while a worker
   may append. Review status can be appended by the coordinator under the
   same audit-file lock.
   If the landed branch closed an issue that belongs to a GitHub milestone
   (ROADMAP.md, "Two milestones"), read the milestone's open count
   (`gh api repos/takibi-lang/takibi/milestones --jq '.[] | "\(.title) \(.open_issues)"'`)
   and, at zero, tell the maintainer in the conversation which milestone was
   reached and the action its description names; the workflow opens the
   reminder issue, this is the same news said at once.

## 4. Pause and restart (for example a host reboot)

Do not rely on workers or conversations surviving a CLI exit. Worktrees,
commits, audit files and issue comments are the restart evidence.

1. At a natural boundary, send every worker a pause message (it commits,
   comments its progress and next step on the issue, appends a due audit).
2. Let a running land finish rather than killing it. If one must be killed,
   kill its whole process group: a killed `scripts/land.sh` once left its
   `make allcheck` child holding the suite lease.
3. Write a Japanese handoff note, `~/.takibi-sessions/handoff.md`: issues in
   progress, worktree paths and branches, branches not yet landed, audit
   files awaiting review, decisions pending.
4. Exit. A new coordinator reads the handoff note and audit files, checks
   `git worktree list`, classifies slices as eligible, decision-blocked or complete, and starts
   fresh workers only for eligible slices, at most one per territory. Use
   the runtime adapter to resume; old worker IDs are not portable.

Restart the coordinator itself periodically: its context grows with every
relay and land, and old parts are summarised away. The natural point is right
after an audit batch has been reviewed, when no worker is running.

## 5. Escalate a stuck worker

Use the runtime adapter for worker replacement and model selection. When a
worker reports `stuck` (or the maintainer wants a stronger model), preserve
its WIP commit and issue note, pause and stop the old worker, then start its
replacement from the saved branch. Select a stronger model only when the
runtime exposes that choice. Read the partial audit and stuck note first.
Check that the new worker does not repeat recorded dead ends; if it does,
the note was too thin -- tell the maintainer.

## Never

- Push except through `land`; land a branch with an escalated item without
  maintainer approval.
- Paraphrase an escalated audit item instead of quoting it, or hide a
  default you applied.
- Touch `~/.takibi-sessions` beyond the audit and decisions directories,
  the handoff note and releasing a removed worktree's port block. When revising `DECISIONS.md`
  defaults or this skill, read past maintainer conversations in
  `~/.takibi-sessions/transcripts/` as evidence of decision tendencies
  (read-only; never commit or quote them into the repo; cite issues instead).
