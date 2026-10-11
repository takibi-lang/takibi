"""The vCPU budget for Python QEMU runners (GitHub issue #719).

Call lease() at the top of main(), before any timing starts. Without a lease
it re-executes this process through scripts/vcpu_lease_run.sh, which waits for
the vCPUs and then runs the same command line again holding them. With one it
returns the guest's vCPU count. Start QEMU as QEMU, never qemu-system-aarch64.
"""

import os
from pathlib import Path
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parent
QEMU = str(SCRIPTS / "qemu.sh")


def _bash(expr: str) -> str:
    return subprocess.run(
        ["bash", "-c", f'. "{SCRIPTS}/vcpu_lease.sh"; {expr}'],
        check=True, capture_output=True, text=True).stdout.strip()


def lease(vcpus: int | None = None) -> int:
    """Hold VCPUS (default: the TAKIBI_QEMU_SMP setting) and return it."""
    if vcpus is None:
        vcpus = int(_bash('echo "$TAKIBI_QEMU_SMP"'))
    if int(_bash("resource_lease_vcpu_held")) >= vcpus:
        return vcpus
    sys.stdout.flush()
    sys.stderr.flush()
    os.execvp("bash", ["bash", str(SCRIPTS / "vcpu_lease_run.sh"), str(vcpus),
                       sys.executable, *sys.argv])
