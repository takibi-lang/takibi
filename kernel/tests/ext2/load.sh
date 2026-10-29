#!/bin/sh
# The stage-1 multicore load of GitHub issue #742: programs Linux
# distributions ship, unmodified, with no threads. It is a finder, not a
# check -- scripts/run_kernel_load.py runs it on demand, nothing in the boot
# does, and a clean run is never the evidence a defect is fixed.
#
# Usage: load.sh SECONDS JOBS LOOPS PHASE...
# Phases, each bracketed by `load: begin NAME` and `load: end NAME status=S`
# so the runner times them and tells a hang from a failure:
#   xargs      BusyBox `xargs -P 4` running JOBS copies of /bin/load-job.sh:
#              each digests two binaries from the root filesystem and
#              compares the digest file with the first job's,
#   fork, exec, pipe
#              stress-ng's process stressors, one at a time, four instances
#              each, for SECONDS seconds (its own metrics follow),
#   hackbench  hackbench's process mode over pipes, LOOPS loops (it prints
#              `Time:`).
# The harness itself uses no pipe and no command substitution: pipes are
# what the pipe and hackbench phases load (GitHub issue #1042), and the
# harness must not depend on what one of its phases is there to find.
# The last line is the verdict the runner reads.
#
# LOAD_ROOT (empty on Takibi) prefixes every path, so the runner's Linux
# reference column runs this same script on the host, with the host-built
# programs under LOAD_ROOT/bin and BusyBox first in PATH.
seconds=$1
jobs=$2
loops=$3
shift 3
failed=0
count=0
root=${LOAD_ROOT:-}
export LOAD_ROOT

busybox mkdir -p "$root/load"
# stress-ng's exec stressor refuses to run as root (GitHub issue #1176), so
# a root caller -- Takibi's shell -- runs every stressor as /etc/passwd's
# `load` user through BusyBox su; an unprivileged caller, the Linux
# reference column, runs them as itself. A file, not a command
# substitution, carries the uid (see above).
busybox id -u >"$root/load/uid"
read uid <"$root/load/uid"
if [ "$uid" -eq 0 ]; then
    busybox chmod 1777 "$root/load"
fi
for phase in "$@"; do
    count=$((count + 1))
    echo "load: begin $phase"
    case "$phase" in
        xargs)
            # The job is a script, not an inline `sh -c '...'`: a long argv
            # fail-stops the kernel in execve (GitHub issue #1039), and
            # that is a lane's to find, not this phase's.
            busybox rm -f "$root"/load/*.sum
            busybox seq 1 "$jobs" >"$root/load/jobs"
            "$root/bin/load-job.sh" 0 &&
                busybox xargs -P 4 -n 1 "$root/bin/load-job.sh" <"$root/load/jobs"
            ;;
        fork|exec|pipe)
            stress="$root/bin/stress-ng --$phase 4 --timeout ${seconds}s --metrics-brief --temp-path $root/load"
            if [ "$uid" -eq 0 ]; then
                busybox su -s /bin/sh load -c "$stress" </dev/null 2>&1
            else
                $stress </dev/null 2>&1
            fi
            ;;
        hackbench)
            "$root/bin/hackbench" -P -p -g 4 -l "$loops" </dev/null 2>&1
            ;;
        *)
            echo "load: unknown phase $phase"
            false
            ;;
    esac
    status=$?
    echo "load: end $phase status=$status"
    [ "$status" -eq 0 ] || failed=$((failed + 1))
done
echo "load: phases=$count failed=$failed"
