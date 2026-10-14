#!/usr/bin/env bash
# Every maintained runner starts QEMU through this, never qemu-system-aarch64
# directly (scripts/check_qemu_vcpu_lease.py enforces it). It refuses a guest
# whose `-smp` exceeds the vCPUs leased by its runner, so a runner that forgot
# to take the lease fails at once instead of oversubscribing the host
# (scripts/vcpu_lease.sh, GitHub issue #719). Without `-smp`, QEMU's
# virt machine has one vCPU.
set -euo pipefail

smp=1
prev=
for arg in "$@"; do
    if [ "$prev" = "-smp" ]; then
        smp="${arg%%,*}"
        smp="${smp#cpus=}"
    fi
    prev="$arg"
done

. "$(dirname "$0")/vcpu_lease.sh"
held="$(resource_lease_vcpu_held)"
if [ "$held" -lt "$smp" ]; then
    echo "error: QEMU with -smp $smp, but its runner leased $held vCPUs." >&2
    echo "       Take the lease before any timing starts:" \
         "resource_lease_vcpu_acquire in bash, scripts/vcpu_lease_run.sh otherwise." >&2
    exit 1
fi
# The kernel's virtio drivers speak only the modern virtio-mmio transport
# (Version 2), and QEMU's virt machine defaults to the legacy one, so every
# guest gets the modern one here rather than from each runner (GitHub issue
# #740).
exec qemu-system-aarch64 -global virtio-mmio.force-legacy=false "$@"
