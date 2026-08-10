# This is the temporary first userspace process. It makes boot policy
# ordinary ext2 data instead of kernel-side argv scenarios.
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
/cat /hello.txt
if [ "$?" -eq 0 ]; then
    echo "busybox exit: 0"
else
    echo "busybox failed"
    exit 1
fi

/uname -a
if [ "$?" -eq 0 ]; then
    echo "busybox uname exit: 0"
else
    echo "busybox uname failed"
    exit 1
fi

# BusyBox od exercises readv(2) against /hello.txt. It then deliberately
# attempts standard input, where this fixture has no descriptor, so its
# non-zero result is the expected proof of the EBADF path rather than an
# init failure.
/od /hello.txt
if [ "$?" -eq 0 ]; then
    echo "busybox od exit: 0"
else
    echo "busybox od failed"
fi

# Keep `exit $?` after /echo so ash cannot tail-call exec the command in
# place of its shell process. This leaves a real child execve, exit, and
# parent wait4/reap lifecycle for the kernel to exercise.
/busybox sh -c '/echo child-exec-ok; exit $?'
if [ "$?" -eq 0 ]; then
    echo "child exec: shell exit: 0"
else
    echo "child exec: shell failed"
    exit 1
fi

# This stays a child shell so the fixture still exercises ash's fork/exec
# lifecycle plus ppoll/read on UART, rather than only the PID 1 shell
# interpreting its own builtin. The runner sends xashread after the blocked
# marker; ${x#x} removes that warm-up sentinel.
/busybox sh -c 'read x; echo shell read: ${x#x}'
if [ "$?" -eq 0 ]; then
    echo "busybox shell read exit: 0"
else
    echo "busybox shell read failed"
    exit 1
fi

# This exact 13 KiB file reaches i_block[12], ext2's first singly-indirect
# entry after all twelve direct blocks. `cat` reaches sendfile(2), proving
# the file reader streams through the indirect pointer rather than treating
# either direct pointers or the one-block staging area as a whole-file limit.
/cat /read_indirect.txt
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
/user_payload

for phase in fd uart telnet; do
    echo "init: phase $phase"
done

echo "init: complete"

# This is deliberately the final action: parent execve replaces PID 1, so
# there is no shell left to continue the script after /bin/echo exits.
exec /bin/echo exec-ok
