#!/usr/bin/env python3
"""A driver that starts a lease-taking QEMU runner holds the lease first.

GitHub issue #719: QEMU runners wait for vCPUs from a host-wide budget
(scripts/vcpu_lease.sh). A driver that starts its own deadline and then
spawns such a runner spends that deadline in the runner's wait, and reports
the wait as a boot failure -- the first four-vCPU allcheck failed race-window
633 and the kernelsh PTY smoke that way. The cure is uniform: the driver
takes the lease itself (the lease() helper, before any timing), and the
runner then finds it on its ancestor and does not wait.

So: a Python file that spawns a lease-taking runner -- a script calling
resource_lease_vcpu_acquire, or `make kernelsh-qemu` -- must call lease(),
and a shell line that wraps one in `timeout` must come after the file takes
its own lease. Runners are found from the tree, so a new one is covered.
"""

import ast
import pathlib
import re
import subprocess
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
NOT_RUNNERS = {"qemu.sh", "vcpu_lease.sh", "vcpu_lease_run.sh",
               "resource_lease.sh", "slowcheck_resource_lease.sh"}
MAKE_RUNNERS = ("kernelsh-qemu",)
SPAWNERS = {("subprocess", name) for name in
            ("run", "Popen", "call", "check_call", "check_output")} | \
           {("os", name) for name in ("execvp", "execv", "execvpe", "execl", "execlp")}


def runners(files):
    names = set(MAKE_RUNNERS)
    for name in files:
        path = pathlib.Path(name)
        if path.suffix == ".sh" and path.name not in NOT_RUNNERS and \
                "resource_lease_vcpu_acquire" in (ROOT / name).read_text(errors="replace"):
            names.add(path.name)
    return names


def strings(node, constants):
    for child in ast.walk(node):
        if isinstance(child, ast.Constant) and isinstance(child.value, str):
            yield child.value
        elif isinstance(child, ast.Name) and child.id in constants:
            yield from constants[child.id]


def python_problems(name, text, runner_names):
    tree = ast.parse(text)
    constants = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            values = [child.value for child in ast.walk(node.value)
                      if isinstance(child, ast.Constant) and isinstance(child.value, str)]
            for target in node.targets:
                if isinstance(target, ast.Name):
                    constants[target.id] = values
    spawned = set()
    leases = False
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Name) and func.id == "lease":
            leases = True
        if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) and \
                (func.value.id, func.attr) in SPAWNERS:
            for value in strings(node, constants):
                for runner in runner_names:
                    if value == runner or value.endswith("/" + runner):
                        spawned.add(runner)
    if spawned and not leases:
        return [f"{name}: spawns {', '.join(sorted(spawned))}, which waits for vCPUs, "
                f"without taking the lease first (the lease() helper before "
                f"any deadline starts)"]
    return []


def shell_problems(name, text, runner_names):
    found = []
    leased = False
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0]
        if "resource_lease_vcpu_acquire" in code:
            leased = True
        if re.search(r"\btimeout\s+[\"$0-9]", code) and not leased and \
                any(runner in code for runner in runner_names):
            found.append(f"{name}:{number}: a timeout around a lease-taking runner, "
                         f"before this script holds the lease")
    return found


def main():
    controls = {"run_x_qemutest.sh", "kernelsh-qemu"}
    bad = 'import subprocess\nsubprocess.run(["bash", "scripts/run_x_qemutest.sh"], timeout=9)\n'
    if not python_problems("x.py", bad, controls) \
            or python_problems("x.py", bad + "lease(1)\n", controls) \
            or not python_problems("x.py", 'import os\nR = "kernelsh-qemu"\nos.execvp("make", ["make", R])\n', controls) \
            or python_problems("x.py", 'P = "scripts/run_x_qemutest.sh"\nprint(open(P).read())\n', controls) \
            or not shell_problems("x.sh", 'timeout 9 bash run_x_qemutest.sh\n', controls) \
            or shell_problems("x.sh", 'resource_lease_vcpu_acquire 1\ntimeout 9 bash run_x_qemutest.sh\n', controls):
        print("FAIL lease-before-deadline: the check's own controls no longer behave")
        return 1
    files = subprocess.run(["git", "ls-files", "scripts/*.py", "scripts/*.sh", "kernel/tests/*.py"],
                           cwd=ROOT, check=True, capture_output=True, text=True).stdout.split()
    runner_names = runners(files)
    found = []
    for name in files:
        if name.endswith("check_lease_before_deadline.py"):
            continue
        text = (ROOT / name).read_text(encoding="utf-8", errors="replace")
        found += (python_problems if name.endswith(".py") else shell_problems)(
            name, text, runner_names)
    if found:
        print("FAIL lease-before-deadline:")
        for line in found:
            print(f"  {line}")
        return 1
    report_pass("lease-before-deadline",
                f"no driver spawns one of the {len(runner_names)} lease-taking QEMU runners "
                f"without holding the lease first",
                runners=len(runner_names), files=len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
