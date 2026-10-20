#!/bin/sh
# GitHub issue #862: BusyBox init's ::restart: image (inittab.shell). PID 1
# exec's this script in place of init, so it runs as pid 1 through the
# interpreter path, and its exit is PID 1's exit: the kernel prints its
# fail-stop line and stops.
echo "init restart: pid=$$"
exit 7
