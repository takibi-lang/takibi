# This is the temporary first userspace process. It intentionally uses ash
# builtins only: external BusyBox applets require the later execve/child
# lifecycle work, while this script already makes boot policy ordinary ext2
# data instead of kernel-side argv scenarios.
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

for phase in fd uart telnet; do
    echo "init: phase $phase"
done

echo "init: complete"
