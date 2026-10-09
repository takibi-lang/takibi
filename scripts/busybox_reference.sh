#!/usr/bin/env bash
# Run the maintained pinned BusyBox ash under QEMU userspace emulation of Linux.
# An on-demand reference for fixtures, outside all build and test lanes.
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: busybox_reference.sh SCRIPT" >&2
    exit 2
fi
if [[ ! -f "$1" || ! -r "$1" ]]; then
    echo "error: SCRIPT must be a readable regular file: $1" >&2
    exit 2
fi
reference_script="$1"
if [[ "$reference_script" != /* ]]; then
    reference_script="$PWD/$reference_script"
fi
reference_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
reference_busybox="$reference_root/kernel/build/user/busybox-static"
if command -v qemu-aarch64 >/dev/null 2>&1; then
    reference_qemu=qemu-aarch64
elif command -v qemu-aarch64-static >/dev/null 2>&1; then
    reference_qemu=qemu-aarch64-static
else
    echo "error: install qemu-user (or qemu-user-static) to run this reference" >&2
    exit 127
fi
if [[ ! -x "$reference_busybox" ]]; then
    echo "error: build the pinned binary with make kernel/build/user/busybox-static" >&2
    exit 2
fi

reference_status=0
"$reference_qemu" "$reference_busybox" ash "$reference_script" || reference_status=$?
printf 'busybox reference: exit status %s\n' "$reference_status" >&2
exit "$reference_status"
