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

# This foreground daemon is an ordinary ash child. Its dynamic BusyBox/musl
# image is selected by the command name, while the shell remains PID 1.
/bin/httpd -f -p 8080 -h /

# Read the retained, kernel-timestamped text ring through Linux syslog(2),
# exactly as the packaged BusyBox dmesg applet does on Linux.
/bin/dmesg
if [ "$?" -eq 0 ]; then
    echo "busybox dmesg exit: 0"
else
    echo "busybox dmesg failed"
    exit 1
fi

for phase in fd uart telnet; do
    echo "init: phase $phase"
done

echo "init: complete"

# The persistent interactive shell is a BusyBox init respawn entry now
# (/etc/inittab), not something this script hands off to. init keeps it
# running and stays PID 1 itself.
