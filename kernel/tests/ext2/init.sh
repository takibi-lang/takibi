#!/bin/sh
# This is the temporary first userspace process. It makes boot policy
# ordinary ext2 data instead of kernel-side argv scenarios.
PATH=/bin:/usr/bin
boot_role=bootstrap

case "$boot_role" in
bootstrap)
    echo "init: ash bootstrap"
    ;;
*)
    echo "init: invalid boot role"
    exit 1
    ;;
esac

# The kernel enters this ash image once. Ordinary applets run through ash's
# child fork/execve path, not through another kernel-side image launch.
/bin/cat /hello.txt
if [ "$?" -eq 0 ]; then
    echo "busybox exit: 0"
else
    echo "busybox failed"
    exit 1
fi

/bin/uname -a
if [ "$?" -eq 0 ]; then
    echo "busybox uname exit: 0"
else
    echo "busybox uname failed"
    exit 1
fi

# BusyBox od exercises readv(2) against /hello.txt. Standard input is now a
# real inherited UART descriptor, matching the shell's other standard fds;
# the named input file therefore completes normally.
/bin/od /hello.txt
if [ "$?" -eq 0 ]; then
    echo "busybox od exit: 0"
else
    echo "busybox od failed"
fi

# Keep `exit $?` after /bin/echo so ash cannot tail-call exec the command in
# place of its shell process. This leaves a real child execve, exit, and
# parent wait4/reap lifecycle for the kernel to exercise.
/bin/sh -c '/bin/echo child-exec-ok; exit $?'
if [ "$?" -eq 0 ]; then
    echo "child exec: shell exit: 0"
else
    echo "child exec: shell failed"
    exit 1
fi

# This remains a child shell, but now exercises an actual interactive ash
# read/eval loop over UART. The runner sends a harmless leading assignment,
# then an observable command and exit after ppoll publishes the blocked marker.
/bin/sh -i
if [ "$?" -eq 0 ]; then
    echo "busybox interactive shell exit: 0"
else
    echo "busybox interactive shell failed"
    exit 1
fi

# This exact 13 KiB file reaches i_block[12], ext2's first singly-indirect
# entry after all twelve direct blocks. `cat` reaches sendfile(2), proving
# the file reader streams through the indirect pointer rather than treating
# either direct pointers or the one-block staging area as a whole-file limit.
/bin/cat /read_indirect.txt
if [ "$?" -eq 0 ]; then
    echo "busybox indirect-file exit: 0"
else
    echo "busybox indirect-file failed"
    exit 1
fi

# GitHub issue #241: the EL0 syscall-ABI test payload (formerly launched
# through a dedicated flat-blob mechanism straight from the kernel's own
# boot sequence) is a real ELF in this filesystem now, launched the same
# way any other external command here is: ash forks and execve()s it.
/bin/user_payload

# GitHub issue #503: what one move between cores costs. Silent on success;
# its numbers are the kernel's `profile: move-cost` records, collected by the
# lane runners. Here, before the busy pair starts, so nothing else computes.
/bin/movecost
if [ "$?" -ne 0 ]; then
    echo "movecost failed"
    exit 1
fi

# GitHub issue #597: mkdirat, renameat and unlinkat on a peer. The kernel
# prints the peer_mutation view's line; this prints only a failure.
/bin/peer-mutate
if [ "$?" -ne 0 ]; then
    echo "peer-mutate failed"
    exit 1
fi

# GitHub issue #610: execve on CPU 1, after one on core 0 as the control.
# The kernel prints the peer_exec view's line; this prints only a failure.
/bin/peer-exec
if [ "$?" -ne 0 ]; then
    echo "peer-exec failed"
    exit 1
fi

# GitHub issue #611: fork on CPU 1, after one on core 0 as the control. The
# kernel prints the peer_fork view's line; this prints only a failure.
/bin/peer-fork
if [ "$?" -ne 0 ]; then
    echo "peer-fork failed"
    exit 1
fi

# Read the retained, kernel-timestamped text ring through Linux syslog(2),
# exactly as the packaged BusyBox dmesg applet does on Linux. Snapshot
# before the variable-length protocol report: its 512-event buffer can
# otherwise evict the first boot marker from the 256-record retained ring.
/bin/dmesg
if [ "$?" -eq 0 ]; then
    echo "busybox dmesg exit: 0"
else
    echo "busybox dmesg failed"
    exit 1
fi

# GitHub issue #606: a window of the stack-ownership protocol as it ran,
# printed by the kernel for scripts/validate_protocol_trace.py to replay
# against StackOwnership.tla. This prints only a failure.
/bin/protocol-trace
if [ "$?" -ne 0 ]; then
    echo "protocol-trace failed"
    exit 1
fi

# GitHub issue #612: the same read on CPU 1, while core 0 keeps logging. The
# kernel prints the peer_syslog view's line; the text itself is discarded.
/bin/taskset -c 1 /bin/dmesg >/dev/null
if [ "$?" -ne 0 ]; then
    echo "peer dmesg failed"
    exit 1
fi

# GitHub issue #627: ash's `wait` for a background job masks SIGCHLD and
# sleeps in rt_sigsuspend until its SIGCHLD handler has run, then returns
# through rt_sigreturn. Without handler delivery it never returns at all.
# ash first tries waitpid(WNOHANG), which reaps a child that has already
# exited without ever sleeping; the children here therefore sleep first, so
# `wait $!` reaches rt_sigsuspend while its child is still alive. The status
# is 3 only if the signal frame carried the right child's result back. The
# sleep is short because it counts against the boot-duration bound.
/bin/sleep 0.3 &
( /bin/sleep 0.3; exit 3 ) &
wait $!
echo "ash wait: background child status=$?"
wait
echo "ash wait: every background child reaped"

# Nested interpreter resolution runs after the existing process-image probes.
/nested/4.sh USERARG
if [ "$?" -ne 0 ]; then
    echo "nested: FAIL five-level chain"
    exit 1
fi
/nested/4.sh USERARG A B C D E F
if [ "$?" -ne 0 ]; then
    echo "nested: FAIL fifteen arguments"
    exit 1
fi
for cpu in 0 1; do
    /bin/taskset -c "$cpu" /bin/nested-exec
    if [ "$?" -ne 0 ]; then
        echo "nested: FAIL rejection lifecycle"
        exit 1
    fi
done

# Session lifecycle checks run after all existing process-image evidence.
for cpu in 0 1; do
    /bin/taskset -c "$cpu" /bin/session
    if [ "$?" -ne 0 ]; then
        echo "session: FAIL lifecycle"
        exit 1
    fi
done

# GitHub issue #630: musl maps a large allocation with mmap and returns it
# with munmap. Each 64 KiB string below is built by doubling and dropped by
# the next round, so little is live at once while the total mapped over the
# loop is several times this process's 512 KiB arena. With munmap a no-op,
# ash ran out of memory partway through.
r=0
while [ "$r" -lt 20 ]; do
    x=aaaaaaaa
    j=0
    while [ "$j" -lt 13 ]; do
        x="$x$x"
        j=$((j + 1))
    done
    r=$((r + 1))
done
echo "ash heap: $r rounds of a ${#x}-byte string, arena reused"
unset x

# GitHub issue #629: a handler for a signal other than SIGCHLD runs, and a
# caught SIGTERM does not take its default (termination). The traps are in
# place before the sender exists; the sender is a subshell, so the signals
# come from another process, and this shell is blocked in wait4 for it
# while they arrive. Both run at that wait4's return, lowest number first.
trap 'echo "ash trap: usr1 caught"' USR1
trap 'echo "ash trap: term caught"' TERM
( kill -USR1 $$ && kill -TERM $$ )
echo "ash trap: sender status=$?"
trap - USR1 TERM
# The edges of the same table: an ignored signal and one whose default is
# ignore are discarded, and kill refuses SIGCONT (no job control) and a
# real-time signal (no action table for one) with EINVAL.
trap '' USR2
( kill -USR2 $$ )
echo "ash trap: ignored usr2 survived"
trap - USR2
( kill -WINCH $$ )
echo "ash trap: default-ignored winch survived"
( kill -CONT $$ ) 2>/dev/null
echo "ash trap: cont refused status=$?"
( kill -34 $$ ) 2>/dev/null
echo "ash trap: real-time refused status=$?"

# Signal and anonymous-memory boundaries run after the cumulative lifecycle
# fixtures. Destructive signal cases are isolated in children of this ELF.
/bin/signal-boundary
if [ "$?" -ne 0 ]; then
    echo "boundary: FAIL fixture"
    exit 1
fi

for phase in fd uart telnet; do
    echo "init: phase $phase"
done

echo "init: complete"

# The persistent HTTP server and interactive shell are BusyBox init respawn
# entries now (/etc/inittab), not children this finite boot script launches.
# init keeps both running and stays PID 1 itself.
