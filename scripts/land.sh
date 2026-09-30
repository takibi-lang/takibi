#!/usr/bin/env bash
# Publish finished work: rebase onto origin/main, run a clean `make allcheck`
# on the rebased HEAD, and fast-forward push exactly that commit when it is
# green. This is the only route by which an agent pushes (AGENTS.md, "Git and
# GitHub safety boundary"; .agents/skills/land/SKILL.md). A direct `git push`
# stays denied in the agents' permission settings; this script exists so the
# rule "the pushed commit is the tested commit" is enforced by code rather
# than remembered.
#
# Exit status:
#   0  pushed (or nothing to push)
#   1  allcheck failed; the log path is printed
#   2  precondition failed: dirty tree, detached HEAD, or not on main
#   3  origin/main moved during the check; run again from the start
#   4  the rebase stopped on a conflict; resolve it, then run again
#
# The allcheck output is kept under .git/takibi-land/ so a symptom can be
# matched against docs/KNOWN_INTERMITTENTS.md after the run, and so are the
# failing lanes' captures (failures/), each bounded to the newest few.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2

branch=$(git symbolic-ref --quiet --short HEAD) || {
    echo "land: detached HEAD; check out main first" >&2
    exit 2
}
if [ "$branch" != "main" ]; then
    echo "land: on branch '$branch', not main" >&2
    exit 2
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "land: uncommitted changes to tracked files; commit them first (never stashed here)" >&2
    exit 2
fi

# A rebase writes commits, and git refuses to when no identity is configured
# (a fresh container has none). Every commit being replayed keeps its own
# author; the committer is taken from HEAD's author, for this one command
# only -- never written to any git config (AGENTS.md, "Git and GitHub safety
# boundary"). An agent identity set in the environment wins.
echo "land: syncing with origin/main"
if ! GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$(git log -1 --format=%an)}" \
     GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$(git log -1 --format=%ae)}" \
     git pull --rebase=merges --no-autostash; then
    echo "land: the rebase stopped; resolve it, then run land again" >&2
    exit 4
fi

tested=$(git rev-parse HEAD)
if [ "$tested" = "$(git rev-parse origin/main)" ]; then
    echo "land: nothing to push; HEAD is origin/main ($tested)"
    exit 0
fi

log_dir=".git/takibi-land"
mkdir -p "$log_dir"
log="$log_dir/allcheck-$tested.log"

# `make clean` below removes _build, and with it every failing lane's archived
# capture (scripts/archive_kernel_failure.sh writes them there). An
# intermittent failure's raw transcript is exactly what a diagnosis needs, and
# the next land run used to destroy it (GitHub issue #657 lost one this way).
# Move them out first, and keep only the newest few of each kind: this
# directory sits in .git, where nothing else prunes it, so an unbounded copy
# per run would fill the disk unnoticed.
keep_failure_archives=5
keep_allcheck_logs=30
failure_root="$log_dir/failures"
for archive_dir in _build/*-failures; do
    [ -d "$archive_dir" ] || continue
    mkdir -p "$failure_root"
    mv "$archive_dir" "$failure_root/$(basename "$archive_dir")-$(date -u +%Y%m%dT%H%M%SZ)-$$"
done
prune_newest() {
    # prune_newest KEEP PATH... : delete all but the newest KEEP entries.
    local keep="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    ls -1dt -- "$@" 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r stale; do
        rm -rf -- "$stale"
    done
}
if [ -d "$failure_root" ]; then
    prune_newest "$keep_failure_archives" "$failure_root"/*
fi
prune_newest "$keep_allcheck_logs" "$log_dir"/allcheck-*.log

echo "land: make clean && make allcheck on $tested (log: $log)"
make clean > "$log" 2>&1
make allcheck 2>&1 | tee -a "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
    echo "land: FAIL allcheck on $tested; log: $log" >&2
    exit 1
fi

if [ "$(git rev-parse HEAD)" != "$tested" ]; then
    echo "land: HEAD moved during the check; refusing to push an untested commit" >&2
    exit 2
fi
git fetch --quiet origin main
if ! git merge-base --is-ancestor origin/main "$tested"; then
    echo "land: origin/main moved during the check; run land again from the start" >&2
    exit 3
fi
if ! git push origin "$tested:refs/heads/main"; then
    echo "land: push rejected; run land again from the start" >&2
    exit 3
fi
echo "land: pushed $tested"
