# Keep a parent ash runnable while its interactive child blocks on UART. A
# foreground child would make this shell block in wait4 at the same time,
# leaving the current scheduler with no runnable process. Background ash
# normally replaces stdin with /dev/null, so preserve the inherited terminal
# on fd 3 first and restore it explicitly in the child.
exec 3<&0
/busybox sh -i <&3 &
while :; do :; done
