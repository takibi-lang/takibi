#!/usr/bin/env python3
"""Every maintained QEMU guest starts through scripts/qemu.sh, under a lease.

GitHub issue #719 put QEMU lanes under a host-wide vCPU budget
(scripts/vcpu_lease.sh). The shim refuses a guest whose runner holds too
few vCPUs, but only a guest started through the shim: a runner that calls
qemu-system-aarch64 directly bypasses the budget and nothing at run time
notices. So a direct invocation is refused here, and a file that starts the
shim must also take the lease. A process-matching pattern (pgrep, pkill)
names the binary without starting it and is allowed.
"""

import ast
import pathlib
import re
import subprocess
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
# The shim itself, its helpers, and the lease control, which writes a fake
# qemu-system-aarch64 to prove the shim refuses an unleased guest.
EXEMPT = {"scripts/qemu.sh", "scripts/check_qemu_vcpu_lease.py",
          "scripts/qemu_vcpu_lease.py", "scripts/slowcheck_resource_lease.sh"}
DIRECT = re.compile(r"qemu-system-aarch64")
MATCHER = re.compile(r"\b(pgrep|pkill)\b")
SHIM = re.compile(r"^[^#]*scripts/qemu\.sh|^from qemu_vcpu_lease import", re.M)
LEASE = re.compile(r"resource_lease_vcpu_acquire|\blease\(")


def problems(name, text):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0] if name.endswith((".sh", ".py")) else line
        if DIRECT.search(code) and not MATCHER.search(code):
            found.append(f"{name}:{number}: starts qemu-system-aarch64 directly;"
                         " use scripts/qemu.sh under a vCPU lease")
    if SHIM.search(text) and not LEASE.search(text):
        found.append(f"{name}: starts scripts/qemu.sh without taking a vCPU lease")
    # The import must be the module's own: one pasted into an embedded script
    # string (a gdb Python block) matches every regex above and then fails
    # with NameError at run time, which is how the churn-gdb lane first broke.
    if name.endswith(".py") and "qemu_vcpu_lease" in text:
        tree = ast.parse(text)
        if not any(isinstance(node, ast.ImportFrom) and node.module == "qemu_vcpu_lease"
                   for node in tree.body):
            found.append(f"{name}: qemu_vcpu_lease is not imported at module level")
    return found


def main():
    # The check must still be able to fail: one direct start, one unleased shim.
    if not problems("x.sh", "qemu-system-aarch64 -smp 2\n") \
            or not problems("x.py", 'from qemu_vcpu_lease import QEMU\n') \
            or problems("x.sh", 'pgrep -f "qemu-system-aarch64.*"\n') \
            or not problems("x.py", 'S = """\nfrom qemu_vcpu_lease import QEMU, lease\n"""\nlease()\n'):
        print("FAIL qemu-vcpu-lease: the check's own controls no longer behave")
        return 1
    files = subprocess.run(["git", "ls-files", "*.sh", "*.py"], cwd=ROOT,
                           check=True, capture_output=True, text=True).stdout.split()
    found, starters = [], 0
    for name in files:
        if name in EXEMPT:
            continue
        text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
        if SHIM.search(text):
            starters += 1
        found += problems(name, text)
    if found:
        print("FAIL qemu-vcpu-lease:")
        for line in found:
            print(f"  {line}")
        return 1
    report_pass("qemu-vcpu-lease",
                f"{starters} QEMU runners start the guest through the leased shim",
                runners=starters)
    return 0


if __name__ == "__main__":
    sys.exit(main())
