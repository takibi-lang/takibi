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

# The ext2 reader currently implements its 12 direct block pointers, so this
# exact 12 KiB file is the largest regular file it supports today. `cat`
# reaches the sendfile(2) path; it must stream all twelve blocks rather than
# treating the kernel's one-block staging area as a whole-file limit.
/cat /read_max.txt
if [ "$?" -eq 0 ]; then
    echo "busybox max-file exit: 0"
else
    echo "busybox max-file failed"
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
