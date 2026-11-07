# One QEMU lane chain per worktree (GitHub issue #1433).
#
# Lanes of one `make` run in parallel on purpose: each takes its own ports
# from the worktree's block. A second, independent chain in the same
# worktree -- another `make kernelcheck-qemu-*` started while the first
# runs -- takes the same ports, so one of them fails with EADDRINUSE and
# later failures show only the overlap as their cause. So the first chain
# to start a guest records itself as the worktree's owner, and a guest of
# any other chain is refused while the owner lives.
#
# The chain is named by TAKIBI_LANE_ROOT_PID, which the root Makefile
# exports once at its top level so every lane of that make shares it. A
# runner started by hand, outside make, is its own chain: the default is
# the process that called scripts/qemu.sh. The owner record is "PID
# STARTTIME" (/proc/PID/stat field 22), so a reused PID is not mistaken
# for a live owner. It lives in the worktree's own git directory, which is
# per worktree and outside the working tree; a tree with no git directory
# uses _build/.
#
# qemu_lane_owner_claim [ROOT_PID] -- returns 0 when this chain may start a
# guest, 1 (with a message naming the owner) when another live chain owns
# the worktree. TAKIBI_QEMU_LANE_OWNER_FILE overrides the record's path
# (the controls use it).

qemu_lane_owner_starttime() {
    local stat
    stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    # Field 22, counted after the parenthesised command name.
    stat="${stat##*) }"
    set -- $stat
    echo "${20}"
}

qemu_lane_owner_file() {
    if [ -n "${TAKIBI_QEMU_LANE_OWNER_FILE:-}" ]; then
        echo "$TAKIBI_QEMU_LANE_OWNER_FILE"
        return
    fi
    local root gitdir
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if gitdir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)"; then
        echo "$gitdir/takibi-qemu-lane-owner"
    else
        mkdir -p "$root/_build"
        echo "$root/_build/.takibi-qemu-lane-owner"
    fi
}

qemu_lane_owner_claim() {
    local me="${1:-${TAKIBI_LANE_ROOT_PID:-$PPID}}"
    local file mine fd owner owner_start live_start
    file="$(qemu_lane_owner_file)"
    mine="$(qemu_lane_owner_starttime "$me")" || {
        echo "error: qemu lane owner: chain process $me is not running" >&2
        return 1
    }
    exec {fd}>"$file.lock"
    flock "$fd"
    if read -r owner owner_start < "$file" 2>/dev/null \
       && [ "$owner" != "$me" ] \
       && live_start="$(qemu_lane_owner_starttime "$owner")" \
       && [ "$live_start" = "$owner_start" ]; then
        exec {fd}>&-
        echo "error: another QEMU lane chain owns this worktree: pid $owner" \
             "($(tr '\0' ' ' < "/proc/$owner/cmdline" 2>/dev/null | cut -c1-120))." >&2
        echo "       Two chains in one worktree share its ports (GitHub issue #1433);" \
             "wait for it, or run the lane in another worktree." >&2
        return 1
    fi
    echo "$me $mine" > "$file"
    exec {fd}>&-
    return 0
}
