---
name: coordinate
description: Run Takibi's Territory A/B queues from one Claude Code session as coordinator -- spawn one territory-worker subagent per issue in its own git worktree, relay decisions and audits to the maintainer, land finished branches one at a time, and pause or restart cleanly. Use when the maintainer asks this session to coordinate, start, resume, pause, or land worker issues.
---

# Coordinate worktree workers

Decided on GitHub issue #753 (maintainer, 2026-10-11). The coordinator is one
interactive Claude Code session. It stays free for the maintainer's own
questions; the issue work happens in background subagents. The maintainer
takes part in only two flows: options -> discussion -> decision, and review
of the end-of-issue audit with its recurrence-prevention proposals.

Talk to the maintainer in Japanese. Everything written to Git or GitHub stays
English ASCII.

## 1. Start a worker

1. Pick the next issue from `ROADMAP.md` for the territory, skipping issues
   that wait on a maintainer decision. Run at most one worker per territory
   (two in total) until the maintainer says otherwise.
2. Choose the audit batch file: `~/.takibi-sessions/audits/<YYYY-MM-DD>_<issues>.md`,
   reusing the open batch until it is presented.
3. Spawn with the Agent tool: `subagent_type: "territory-worker"`,
   `isolation: "worktree"`, a short `description` naming the issue, and a
   prompt giving the issue number, the territory, the audit file, and, when
   resuming, the branch and handoff note to read. Pass `model` only to
   escalate (section 5). Record issue -> agent -> worktree in a running
   table in the conversation.

Nothing else is needed for isolation. Each worktree claims its own QEMU port
block automatically (`scripts/qemu_session_ports.sh` names it after the
worktree), and every QEMU guest leases vCPUs from the host-wide budget
(`scripts/vcpu_lease.sh`), so concurrent lanes wait rather than collide.

## 2. Relay

- A worker returns `needs decision`: show the options to the maintainer,
  translated faithfully, with the worker's recommendation. After the
  decision, record it on the issue (`github-workflow`) and continue the same
  worker with SendMessage, so its context is kept.
- Maintainer advice for a running worker ("read the application-side
  source", ...): send it verbatim with SendMessage.
- Visibility: you do not see a worker's tool output. Check progress through
  its worktree (`git -C <worktree> log --oneline main..HEAD`, `git -C
  <worktree> status`, build logs under its `_build/`), or ask it for status
  with SendMessage.
- Stuck detection, coordinator side: when you check in (at every maintainer
  turn and every worker report), look at each running worker's time since
  its last commit and repeated failures in its logs; if one looks stuck for
  more than about an hour, tell the maintainer.

## 3. Land, one branch at a time

Only the coordinator lands, from the main checkout (`scripts/land.sh`
refuses any branch but `main`).

1. The worker reported `done` and its audit is in the batch file.
2. **Audit gate.** A branch is not landed until the maintainer has reviewed
   its audit and the agreed cheap prevention is committed. Present audits
   every few issues or at a natural boundary: show the batch file's text
   verbatim (no summary), then stop and wait for the maintainer. If the
   agreed prevention is not done yet, continue the worker with SendMessage
   to do it.
3. **Land gates on the branch.** The space checkpoint is current
   (`python3 scripts/space_checkpoint.py --base main --head <branch>` passes),
   and the ROADMAP.md update and issue-closing commit are on the branch.
   `scripts/land.sh` refuses a stale checkpoint before allcheck; #720, #719
   and #608 each cost a failed land round on it (2026-10-12). If a gate is
   missing, continue the worker with SendMessage to add it.
4. In the main checkout, clean and on `main`:
   `git -C <worktree> rebase main`, then `git merge --ff-only <branch>`.
   Resolve integration conflicts yourself when they are mechanical (for
   example `docs/SPACE_CHECKPOINT.json` touched by two workers); otherwise
   send the conflict back to the worker.
5. Follow the `land` skill (`scripts/land.sh`). Never land two branches
   concurrently; never edit the tree while a land runs.
6. After a green land: `git worktree remove <worktree>` (agent worktrees
   are locked, so this needs `-f -f`, which the maintainer may have to run), delete the branch,
   and release its port block:
   `bash -c '. scripts/qemu_session_ports.sh; qemu_session_release_block <name>'`
   where `<name>` is `$TAKIBI_SESSION-wt-<worktree directory name>`.
   Move the batch file's reviewed sections under a `reviewed` heading or
   start a new batch.

## 4. Pause and restart (for example a host reboot)

Exiting the CLI stops every worker and loses its conversation; worktrees,
commits, audit files and issue comments survive.

1. At a natural boundary, send every worker a pause message (it commits,
   comments its progress and next step on the issue, appends a due audit).
2. Let a running land finish rather than killing it. If one must be killed,
   kill its whole process group: a killed `scripts/land.sh` once left its
   `make allcheck` child holding the suite lease.
3. Write a Japanese handoff note, `~/.takibi-sessions/handoff.md`: issues in
   progress, worktree paths and branches, branches not yet landed, audit
   files awaiting review, decisions pending.
4. Exit. A new coordinator reads the handoff note and audit files, checks
   `git worktree list`, and starts a fresh worker per worktree with a resume
   prompt (SendMessage to the old workers is no longer possible).

Restart the coordinator itself periodically: its context grows with every
relay and land, and old parts are summarised away. The natural point is right
after an audit batch has been reviewed, when no worker is running.

## 5. Escalate a stuck worker

A model is fixed at spawn. When a worker reports `stuck` (or the maintainer
wants a stronger model): make sure its WIP is committed and its stuck note is
on the issue, stop it (TaskStop) if it is still running, then spawn a new
territory-worker with `model` set to the stronger model, `isolation:
"worktree"`, and a prompt to resume from the old branch (`git switch -c
<new> <old-branch>` in the new worktree) and the stuck note. Check that the
new worker does not repeat the recorded dead ends; if it does, the note was
too thin -- tell the maintainer.

## Never

- Push except through `land`; land a branch whose audit is unreviewed.
- Summarise an audit instead of showing it verbatim.
- Touch `~/.takibi-sessions` beyond the audit directory, the handoff note and
  releasing a removed worktree's port block.
