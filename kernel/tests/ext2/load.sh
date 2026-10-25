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
# The harness itself uses no pipe and no command substitution: the kernel
# has no pipe(2) yet (GitHub issue #1042), and the load must not depend on
# what one of its phases is there to find.
# The last line is the verdict the runner reads.
seconds=$1
jobs=$2
loops=$3
shift 3
failed=0
count=0

busybox mkdir -p /load
for phase in "$@"; do
    count=$((count + 1))
    echo "load: begin $phase"
    case "$phase" in
        xargs)
            # The job is a script, not an inline `sh -c '...'`: a long argv
            # used to fail-stop the kernel in execve (GitHub issue #1039),
            # and that is a lane's to find, not this phase's.
            busybox rm -f /load/*.sum
            busybox seq 1 "$jobs" >/load/jobs
            /bin/load-job.sh 0 &&
                busybox xargs -P 4 -n 1 /bin/load-job.sh </load/jobs
            ;;
        fork|exec|pipe)
            /bin/stress-ng --"$phase" 4 --timeout "${seconds}s" \
                --metrics-brief --temp-path /load </dev/null 2>&1
            ;;
        hackbench)
            /bin/hackbench -P -p -g 4 -l "$loops" </dev/null 2>&1
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
