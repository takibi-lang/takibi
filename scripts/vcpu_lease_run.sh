#!/usr/bin/env bash
# vcpu_lease_run.sh N COMMAND [ARG...] -- run COMMAND holding N vCPUs of the
# host-wide budget (scripts/vcpu_lease.sh, GitHub issue #719). The Python
# QEMU runners re-execute themselves through this before they start any
# timing; bash runners call resource_lease_vcpu_acquire directly.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 VCPUS COMMAND [ARG...]" >&2
    exit 2
fi
want="$1"
shift

. "$(dirname "$0")/vcpu_lease.sh"
resource_lease_vcpu_acquire "$want" "${1##*/} ${2##*/}"
exec "$@"
