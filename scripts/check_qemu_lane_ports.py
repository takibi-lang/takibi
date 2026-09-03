#!/usr/bin/env python3
"""Refuse a build in which two QEMU lanes claim the same protocol:port.

GitHub issue #414's lane took 18683-18686 because only one of the two places
a lane's ports are written down was checked. `make kernelcheck` runs every
kernelcheck-*-qemu lane concurrently, and kernelcheck-qemu-debug's ports are
not in any script -- they are `env KERNEL_QEMU_SERIAL_PORT=18683 ...` in the
Makefile recipe, overriding the shared runner's defaults. The collision
surfaced as that lane's host-side network peer timing out with no UART
output, i.e. as a failure that named the kernel for something the kernel was
never asked about.

scripts/qemu_port_guard.py (issue #407) already catches a busy port at
RUNTIME, and could not catch this: it is told one lane's claims and compares
them against what is bound right now, so two lanes whose claims overlap only
partially -- tcp:18684 here, udp:18684 there -- pass it individually and
still ruin each other's run. This checks the claims against each other,
before anything runs.

What it reads, per lane:

  * the `qemu_port_guard.py` invocation in each scripts/run_kernel_*.sh,
    which is where a lane declares its protocol:port pairs by construction;
  * the `VAR="${ENV_NAME:-DEFAULT}"` line each of those variables comes from;
  * every Makefile recipe that runs the script, for `ENV_NAME=NNNNN`
    overrides -- one recipe line is one lane INSTANCE, so the same runner
    invoked three times with three different port sets is three lanes.

A lane that does not call the port guard has nothing to declare and is
skipped, which is also the honest answer: scripts/run_kernel_oops_qemutest.sh
writes its UART to a file and only opens a gdbstub, and it does call the
guard for that one port.
"""

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT_GLOB = "run_kernel_*.sh"

GUARD_CALL = re.compile(
    r"qemu_port_guard\.py\"?\s+(?P<args>(?:\\\s*\n|[^\n])*?)\s*(?:\|\|\s*exit|\n)",
    re.MULTILINE,
)
GUARD_ARG = re.compile(r"\"(?P<proto>tcp|udp):\$(?P<var>[A-Z_]+)\"")
VAR_DEFAULT = re.compile(
    r"^(?P<var>[A-Z_]+)=\"\$\{(?P<env>[A-Z0-9_]+):-(?P<default>\d+)\}\"", re.MULTILINE
)
ENV_OVERRIDE = re.compile(r"(?P<env>[A-Z0-9_]+)=(?P<port>\d+)")

SESSION_PORTS = REPO_ROOT / "scripts" / "qemu_session_ports.sh"


def session_port_constants():
    """The block geometry, read from the one file that defines it."""
    text = SESSION_PORTS.read_text(encoding="utf-8")
    wanted = (
        "QEMU_SESSION_PORT_STRIDE",
        "QEMU_SESSION_PORT_BLOCKS",
        "QEMU_SESSION_EPHEMERAL_FLOOR",
        "QEMU_SESSION_REPEAT_BASE",
        "QEMU_SESSION_REPEAT_STEP",
        "QEMU_SESSION_REPEAT_MAX_SAMPLES",
    )
    found = {}
    for name in wanted:
        match = re.search(rf"^{name}=(\d+)$", text, re.MULTILINE)
        if match is None:
            print(f"ERROR\t{SESSION_PORTS.name}: no {name}=N line to read")
            return None
        found[name] = int(match.group(1))
    return found


def check_block_geometry(ports):
    """A session's whole port set must fit in one block, and the highest block
    must stay below the ephemeral range. Both hold today by a wide margin; a
    lane added outside the window is what this is here to catch."""
    constants = session_port_constants()
    if constants is None:
        return False
    stride = constants["QEMU_SESSION_PORT_STRIDE"]
    blocks = constants["QEMU_SESSION_PORT_BLOCKS"]
    floor = constants["QEMU_SESSION_EPHEMERAL_FLOOR"]

    low, high = min(ports), max(ports)
    span = high - low
    ok = True
    if span >= stride:
        print(
            f"ERROR\tlane ports span {span + 1} ({low}..{high}) but one session "
            f"block is {stride} wide, so two sessions would overlap. Move the "
            f"outlying lane or raise QEMU_SESSION_PORT_STRIDE in "
            f"{SESSION_PORTS.name} (and lower the block count to match)."
        )
        ok = False
    top = high + stride * (blocks - 1)
    if top >= floor:
        print(
            f"ERROR\tthe highest session block reaches {top}, at or above the "
            f"ephemeral floor {floor}. Lower QEMU_SESSION_PORT_BLOCKS in "
            f"{SESSION_PORTS.name} or move the lanes down."
        )
        ok = False

    # The repeated-lane window shares the block, so it has to start above every
    # declared lane and end before the next session's block begins.
    repeat_base = constants["QEMU_SESSION_REPEAT_BASE"]
    repeat_top = (
        repeat_base
        + constants["QEMU_SESSION_REPEAT_STEP"]
        * constants["QEMU_SESSION_REPEAT_MAX_SAMPLES"]
        - 1
    )
    block_top = low + stride - 1
    if repeat_base <= high:
        print(
            f"ERROR\tthe repeat window starts at {repeat_base}, at or below the "
            f"highest lane port {high}, so a repeated sample can take a lane's "
            f"own port. Raise QEMU_SESSION_REPEAT_BASE in {SESSION_PORTS.name}."
        )
        ok = False
    if repeat_top > block_top:
        print(
            f"ERROR\tthe repeat window ends at {repeat_top}, past this block's "
            f"last port {block_top}, so a long repeat run reaches into the next "
            f"session's block. Lower QEMU_SESSION_REPEAT_MAX_SAMPLES or raise "
            f"QEMU_SESSION_PORT_STRIDE in {SESSION_PORTS.name}."
        )
        ok = False
    return ok


def lane_claims(script: pathlib.Path):
    """[(proto, env_name, default_port)] this script declares to the guard."""
    text = script.read_text(encoding="utf-8")
    defaults = {
        m.group("var"): (m.group("env"), int(m.group("default")))
        for m in VAR_DEFAULT.finditer(text)
    }
    claims = []
    for call in GUARD_CALL.finditer(text):
        for arg in GUARD_ARG.finditer(call.group("args")):
            var = arg.group("var")
            if var not in defaults:
                print(
                    f"ERROR\t{script.name}: {arg.group('proto')}:${var} is passed to "
                    "the port guard but has no VAR=\"${ENV:-DEFAULT}\" line to read a "
                    "default from"
                )
                return None
            env, default = defaults[var]
            claims.append((arg.group("proto"), env, default))
    return claims


def makefile_instances(script_name: str):
    """[(label, {env: port})] -- one entry per Makefile recipe running it."""
    makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
    instances = []
    for line in makefile.splitlines():
        if script_name not in line:
            continue
        stripped = line.strip()
        if not stripped.startswith("@") and not stripped.startswith("bash"):
            continue
        overrides = {
            m.group("env"): int(m.group("port")) for m in ENV_OVERRIDE.finditer(line)
        }
        instances.append((stripped, overrides))
    return instances


def main() -> int:
    claimed = {}
    failed = False
    lanes = 0
    for script in sorted((REPO_ROOT / "scripts").glob(SCRIPT_GLOB)):
        claims = lane_claims(script)
        if claims is None:
            return 1
        if not claims:
            continue
        instances = makefile_instances(script.name) or [(f"{script.name} (defaults)", {})]
        for label, overrides in instances:
            lanes += 1
            for proto, env, default in claims:
                port = overrides.get(env, default)
                key = (proto, port)
                where = f"{script.name} [{env}]"
                if key in claimed and claimed[key][0] != label:
                    print(
                        f"ERROR\t{proto}:{port} is claimed twice:\n"
                        f"  {claimed[key][1]}\n    in {claimed[key][0][:110]}\n"
                        f"  {where}\n    in {label[:110]}"
                    )
                    failed = True
                    continue
                claimed[key] = (label, where)
    if failed:
        print(
            "FAIL qemu-lane-ports: two lanes that `make kernelcheck` runs "
            "concurrently claim the same port"
        )
        return 1
    if not claimed:
        print("FAIL qemu-lane-ports: no lane declared a port")
        return 1
    if not check_block_geometry([port for _proto, port in claimed]):
        print(
            "FAIL qemu-lane-ports: the lane ports do not fit the per-session "
            "block geometry"
        )
        return 1
    constants = session_port_constants()
    print(
        f"PASS qemu-lane-ports: {lanes} lane instances, "
        f"{len(claimed)} protocol:port claims, no duplicates, "
        f"{constants['QEMU_SESSION_PORT_BLOCKS']} session blocks fit"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
