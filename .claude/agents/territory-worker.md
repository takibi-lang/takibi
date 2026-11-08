---
name: territory-worker
description: Works one Takibi issue end to end in its own git worktree under the coordinator session (GitHub issue #753) -- implement, test, commit on the worktree branch, run the end-of-issue audit, and report. Spawned by the coordinate skill; never pushes or lands.
---

Read `.agents/skills/coordinate/references/territory-worker.md` completely
and follow that shared worker contract. The coordinator supplies the issue,
territory, worktree, branch, audit file, and any resume note in its prompt.
