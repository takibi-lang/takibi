# Sourced (bash): the CPU a lane's processes used (GitHub issue #1198).
#
# The lane budget (scripts/check_lane_budget.py) once summed wall time less
# vCPU lease waits, and wall time stretches with host contention: one lane
# ran 269 s alone and 340 s inside allcheck, and the sum drifted by hundreds
# of seconds with no lane doing more work. CPU seconds -- user plus system
# time of every child the lane waited for, getrusage(RUSAGE_CHILDREN) --
# count work rather than waiting, whoever else is on the host.
#
# lane_cpu_ms VAR stores in VAR this shell's children's user+sys CPU so far,
# in milliseconds. A caller takes it before and after the lane and records
# the difference. It must run in the lane's own shell, never in `$(...)` or
# a pipeline: those are forked subshells, whose children's usage starts at
# zero. Only waited-for descendants count, which is every guest here:
# scripts/qemu.sh execs QEMU in the foreground of its runner.

lane_cpu_ms() {
    local dir file line
    dir="${TAKIBI_LANE_TIMING_DIR:-${TMPDIR:-/tmp}}"
    file="$dir/.lane-cpu.$$.$BASHPID"
    # Empty on any failure: the receipt then carries no CPU, which the
    # budget refuses, rather than a zero that would read as no work.
    printf -v "$1" '%s' ''
    mkdir -p "$dir" 2>/dev/null
    { times >"$file"; } 2>/dev/null || return 0
    line="$(sed -n 2p "$file")"
    rm -f "$file"
    if [[ "$line" =~ ^([0-9]+)m([0-9]+)[.,]([0-9]{3})s\ ([0-9]+)m([0-9]+)[.,]([0-9]{3})s$ ]]; then
        printf -v "$1" '%s' $((
            10#${BASH_REMATCH[1]} * 60000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]}
          + 10#${BASH_REMATCH[4]} * 60000 + 10#${BASH_REMATCH[5]} * 1000 + 10#${BASH_REMATCH[6]}))
    else
        echo "lane_cpu: cannot read times output '$line'" >&2
    fi
}

# lane_cpu_seconds BEFORE AFTER -- print the CPU between two lane_cpu_ms
# readings as seconds with three decimals; nothing when either is missing.
lane_cpu_seconds() {
    [ -n "$1" ] && [ -n "$2" ] || return 0
    local ms=$(($2 - $1))
    printf '%d.%03d\n' $((ms / 1000)) $((ms % 1000))
}
