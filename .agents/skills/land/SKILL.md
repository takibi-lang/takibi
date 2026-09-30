---
name: land
description: Integrate and publish finished work -- rebase onto origin/main, run a clean `make allcheck` on the rebased HEAD, and push exactly that HEAD when it is green. Use at a natural boundary (an issue finished, a milestone, a fix whose recurrence prevention is done), not after every commit. Do not use to test work in progress.
---

# Land finished work

The rule this procedure exists for: **the commit that is pushed is the commit
that `make allcheck` passed.** Rebasing after the check would publish a
combination nobody tested.

## Before starting

- Every change is committed and the working tree is clean. If it is not,
  stop and say so. Never stash or auto-stash: the uncommitted change may be
  the maintainer's.
- The unit is finished. For every defect fixed in it, the `defect-followup`
  skill has been completed.

## Procedure

Run `scripts/land.sh`. It is the only way an agent pushes: a direct
`git push` stays denied in the permission settings, and the script enforces
the rule above in code. It:

1. refuses a dirty tree, a detached HEAD, or a branch other than `main`;
2. runs `git pull --rebase=merges --no-autostash`;
3. records `HEAD` as the tested commit and runs
   `make clean && make allcheck`, logging to
   `.git/takibi-land/allcheck-<commit>.log`;
   before that clean it moves every failing lane's archived capture
   (`_build/*-failures`) to `.git/takibi-land/failures/`, and keeps only the
   newest five of those and thirty allcheck logs, so evidence survives the next
   run and the directory cannot grow without bound;
4. pushes exactly the tested commit as a fast-forward of `main`, and only
   if `HEAD` did not move and `origin/main` is still its ancestor.

Act on its exit status:

| Status | Meaning | What to do |
| --- | --- | --- |
| 0 | pushed, or nothing to push | report |
| 1 | allcheck red | see below |
| 2 | precondition failed | fix it (commit, check out `main`) and rerun |
| 3 | `origin/main` moved | rerun; the whole allcheck runs again. After two such rounds, stop and report |
| 4 | rebase stopped | usually a conflict: resolve it if you understand it, otherwise stop and ask; then rerun. The script supplies a committer identity for the rebase itself, so a missing git identity is not a cause |

## When allcheck is red

Follow AGENTS.md: a red allcheck comes before any other work.

- **Known intermittent.** If the failing log contains a Symptom string
  from `docs/KNOWN_INTERMITTENTS.md`, you may rerun allcheck **once**.
  Before rerunning, comment on that row's issue with the date, the lane, the
  commit, and the run's lane timing artifact path, and update the row's
  "Last seen" date, then run `scripts/land.sh` again. A second red run is a
  real failure, whatever it matches.
- **Real failure.** Diagnose it (use `debug-kernel` for kernel failures), fix
  it in a new commit, run `defect-followup` for it, and start again from
  step 1.
- **Hardware absent.** A runner that finds no board refuses with a message
  naming the device, for example `no Raspberry Pi Debug Probe ttyACM device
  found`. A lease can also report consecutive reset or load failures that
  need a power cycle. In either case, **stop and wait for the maintainer**.
  Do not push on `make cicheck` alone and do not retry. The board may be
  unplugged on purpose, for example while another session runs a
  multi-hour soak. Waiting for a lease another session holds is normal and
  needs no action.

## Report

Tell the maintainer, in the language of the conversation, in about three
lines: pushed commit and what it contains; or red, with the lane, the cause,
and what happens next; or stopped, with what the maintainer needs to do.
