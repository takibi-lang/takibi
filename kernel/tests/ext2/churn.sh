#!/bin/sh
# The process-churn workload (GitHub issue #584): fork, exec, exit, signal
# and wait, repeatedly, with children landing on whichever cores ordinary
# placement picks. It is a finder, not a check -- scripts/run_kernel_churn.py
# runs it on demand and nothing in the boot does. Each round:
#   - an exec'd child that exits at once,
#   - a subshell that exits 3 after a short sleep, so `wait $!` reaches
#     rt_sigsuspend while it is still alive (ash tries WNOHANG first),
#   - an exec'd sleeper killed with SIGTERM from here.
# A status other than the one each child must return is counted, and the
# last line is the verdict the runner reads.
rounds=${1:-100}
i=0
mismatched=0
while [ "$i" -lt "$rounds" ]; do
    /bin/echo "churn $i" >/dev/null &
    ( /bin/sleep 0.05; exit 3 ) &
    exiter=$!
    /bin/sleep 5 &
    sleeper=$!
    kill "$sleeper"
    wait "$exiter"
    [ "$?" -eq 3 ] || mismatched=$((mismatched + 1))
    wait "$sleeper"
    [ "$?" -eq 143 ] || mismatched=$((mismatched + 1))
    wait
    i=$((i + 1))
    # A heartbeat, so a runner can tell a hang from a long run.
    if [ $((i % 500)) -eq 0 ]; then echo "churn: progress $i"; fi
done
echo "churn: rounds=$i mismatched=$mismatched"
