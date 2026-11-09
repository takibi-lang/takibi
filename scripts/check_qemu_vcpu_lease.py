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
# A colon-terminated binary name is diagnostic text, not that executable.
# Exclude only this occurrence; another bare name on the same line still fails.
TERMINATING_DIAGNOSTIC = re.compile(r": terminating\b")
MATCHER = re.compile(r"\b(pgrep|pkill)\b")
# GitHub issue #1442: a file RUNS the shim when the shim is a command, not
# when it merely names it (a grep of it, a message about it). A command is
# the shim's path in command position on a shell line -- after optional
# `exec`, `timeout N`, `nice [-n N]`, `env` and VAR=value words -- or the
# head of a Python argv list (`[os.path.join(..., "scripts/qemu.sh"), ...`,
# `[str(root / 'scripts/qemu.sh'), ...`), or an import of the leased
# wrapper.
SHIM = re.compile(
    r"""^\s*(?:(?:exec|env|timeout\s+\S+|nice(?:\s+-n\s*\S+)?|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*"""
    r"""["']?[^"'\s#]*scripts/qemu\.sh["']?(?:\s|$)"""
    r"""|\[\s*(?:[\w.]+\([^)\n]*)?["'][^"'\n]*scripts/qemu\.sh["']"""
    r"""|^\s*from qemu_vcpu_lease import""", re.M)
LEASE = re.compile(r"resource_lease_vcpu_acquire|\blease\(")


def problems(name, text):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0] if name.endswith((".sh", ".py")) else line
        direct = any(not TERMINATING_DIAGNOSTIC.match(code, match.end())
                     for match in DIRECT.finditer(code))
        if direct and not MATCHER.search(code):
            found.append(f"{name}:{number}: starts qemu-system-aarch64 directly;"
                         " use scripts/qemu.sh under a vCPU lease")
    if SHIM.search(text) and not LEASE.search(text):
        found.append(f"{name}: starts scripts/qemu.sh without taking a vCPU lease")
    # The import must be the module's own: one pasted into an embedded script
    # string (a gdb Python block) matches every regex above and then fails
    # with NameError at run time, which is how the churn-gdb lane first broke.
    # Only an import statement counts: a file merely naming this check
    # (scripts/land_env_members.py, #1389) is not a lease user.
    if name.endswith(".py") and re.search(r"^\s*(?:from|import)\s+qemu_vcpu_lease\b", text, re.M):
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
            or not problems("x.py", 'S = """\nfrom qemu_vcpu_lease import QEMU, lease\n"""\nlease()\n') \
            or not problems("x.sh", '"$R/scripts/qemu.sh" -smp 2 \\\n') \
            or not problems("x.sh", 'timeout "$T" "$R/scripts/qemu.sh" -m 1024\n') \
            or not problems("x.py", 'cmd = [os.path.join(R, "scripts/qemu.sh"), "-m"]\n') \
            or not problems("x.sh", "command = [str(root / 'scripts/qemu.sh'), '-m']\n") \
            or problems("x.sh", 'grep -q gate "$R/scripts/qemu.sh" || fail "scripts/qemu.sh has no gate"\n') \
            or problems("x.py", 'print("start guests through scripts/qemu.sh")\n'):
        print("FAIL qemu-vcpu-lease: the check's own controls no longer behave")
        return 1
    diagnostic_cases = (
        ('x.py', 'rx = rb"qemu-system-aarch64: terminating on signal 15"', False),
        ('x.py', 'rx = rb"qemu-system-aarch64: terminating|other"', False),
        ('x.sh', 'qemu-system-aarch64: terminating; qemu-system-aarch64 -smp 2', True),
        ('x.sh', 'qemu-system-aarch64 -smp 2; echo "qemu-system-aarch64: terminating"', True),
        ('x.py', 'print("qemu-system-aarch64: terminating"); subprocess.run(["qemu-system-aarch64"])', True),
        ('x.py', 'subprocess.run(["qemu-system-aarch64", "-smp", "2"])', True),
        ('x.py', 'rx = "qemu-system-aarch64: terminatingly"', True),
    )
    for name, text, refused in diagnostic_cases:
        if bool(problems(name, text)) != refused:
            print('FAIL qemu-vcpu-lease: diagnostic occurrence control: ' + text)
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
                runners=starters, diagnostics=len(diagnostic_cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
