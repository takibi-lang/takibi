# Runtime adapters

The shared coordinate procedure and worker contract define behavior. Runtime
names below only adapt spawning, messaging, waiting and stopping. Inspect the
available tool schemas before calling them; do not invent unavailable fields
or treat instructions as a substitute for tool permissions.

## Claude Code

Use Agent with `subagent_type: "territory-worker"` and
`isolation: "worktree"`. The definition in
`.claude/agents/territory-worker.md` loads the shared worker contract.
For resume, inspect the preserved worktree first. Start a fresh worker
without automatic worktree creation, requiring it to change to that absolute
worktree before any command; confirm cwd and branch. If the runtime cannot
launch there, use a newly isolated worktree and a unique branch based on the
saved HEAD (`git switch -c <unique-branch> <saved-head>`), preserving the old
worktree and recording the replacement in the handoff. Never try to check
out the old branch in two worktrees.
Use SendMessage for follow-up instructions and TaskStop when available to
stop a worker. Record the worktree actually returned by the tool.

## Codex

Use the available subagent tools (for example spawn_agent, send_input,
wait_agent and close_agent). A named Claude agent definition and Claude's
`isolation` argument are not portable inputs. In the spawn prompt, require
the shared worker contract and an explicit absolute working directory.

Before spawning, create a separate branch and Git worktree:

```
git worktree add -b <unique-branch> <main-checkout>/.claude/worktrees/<unique-name> origin/main
```

For a resume, inspect `git worktree list --porcelain`, branch and status first.
Reuse the existing worktree if no worker owns it. Never create a second worker
in that tree or check out an already-owned branch elsewhere. Ask the worker
to confirm its cwd and branch before editing. Tool-level agent separation
alone is not Git worktree isolation.

The `.claude/worktrees/` directory is retained as the existing runner and
`make prune-worktrees` compatibility location for both agents. Its name does
not assign ownership to Claude. Do not move existing worktrees for a runtime
change. Workers use the commit identity of the agent actually running them.

## Common limits

If subagent tools are unavailable, report that the two-worker workflow cannot
run in this runtime; preserve the handoff and do not simulate parallel workers
in the coordinator's checkout. If model selection is unavailable, preserve
the stuck report and ask the maintainer to choose a supported replacement.

Send a cooperative pause before closing a worker. A returned tool status is
not evidence that a child build or land process has stopped: inspect any
recorded process and lease before restarting work. Do not stop another
session's processes. Restarted sessions use files, branches and issue comments
as evidence; old conversation IDs are only diagnostic context.
