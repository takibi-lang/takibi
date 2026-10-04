#!/usr/bin/env python3
"""Controls for the host peer's readiness waits, with no QEMU in the room.

`scripts/kernel_net_test.py` waits for four markers the UART driver touches:
the kernel network link, the init socket listener, the HTTP daemon's listener,
and the init-managed HTTPd. Each wait exists so the
request phase after it establishes readiness instead of assuming it (GitHub
issues #387, #515, #519). Each also has a give-up branch that prints what was
missing -- and that branch is the one part a passing run never reaches, so
until this file existed nothing had ever executed it.

Worse, the give-up could not have printed. Both lanes run the peer as
`timeout "$TIMEOUT_SECS" python3 kernel_net_test.py`, where TIMEOUT_SECS is
`${KERNEL_QEMU_TIMEOUT:-90}`, and the interactive wait was a flat 90.0s
measured from a point several seconds into the run. It could only ever expire
after the kill, so a guest that never became interactive-ready produced status
124 and silence -- the same "no line saying why" this wait was added to end.
The daemon wait's own comment said the budget had to stay under the outer one,
which is how the sibling was found.

So the property under test is not "the wait waits". It is that the wait GIVES
UP IN TIME TO SPEAK, for every outer budget the lanes actually use.
"""

import json
import contextlib
import io
import os
import runpy
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import Mock, patch

from pass_line import CaseCount

ROOT = Path(__file__).resolve().parent.parent
PEER = ROOT / "scripts" / "kernel_net_test.py"

# The (no-progress, ceiling) pairs the shells pass: the defaults when neither
# variable is set, and the pair `make cicheck-as-ci` sets for a slower runner.
# GitHub issue #620: the outer kill is the ceiling now; the no-progress
# budget is each wait's own.
OUTER_BUDGETS = ((90.0, 270.0), (240.0, 720.0))


def load(budgets):
    """Import the peer with given budgets, without running main()."""
    env = dict(os.environ)
    if budgets is None:
        env.pop("KERNEL_QEMU_TIMEOUT", None)
        env.pop("KERNEL_QEMU_CEILING", None)
    else:
        env["KERNEL_QEMU_TIMEOUT"] = str(int(budgets[0]))
        env["KERNEL_QEMU_CEILING"] = str(int(budgets[1]))
    probe = (
        "import runpy, sys, json, time;"
        "sys.argv = ['kernel_net_test.py'];"
        f"m = runpy.run_path({str(PEER)!r}, run_name='not_main');"
        "print(json.dumps({'budget': m['MARKER_BUDGET_SECONDS'],"
        " 'outer': m['OUTER_BUDGET_SECONDS'],"
        " 'started': m['STARTED_AT'], 'now': time.monotonic()}))"
    )
    out = subprocess.run([sys.executable, "-c", probe], env=env,
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(f"FAIL net-readiness control: importing the peer with "
              f"budgets {budgets} failed\n{out.stderr}")
        return None
    return json.loads(out.stdout)


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def timed_wait(exists_after, idle_first=0.0):
    """Run wait_for_marker against a marker that appears after N seconds.

    Returns (output, elapsed). `exists_after` of None means the marker is
    never created. `idle_first` spends that long in the peer before the wait
    starts, as the phases before a real wait do.
    """
    CASES.note()
    with tempfile.TemporaryDirectory() as work:
        marker = Path(work) / "ready"
        if exists_after == 0:
            marker.write_bytes(b"")
        probe = (
            "import runpy, sys, time;"
            "sys.argv = ['kernel_net_test.py'];"
            f"m = runpy.run_path({str(PEER)!r}, run_name='not_main');"
            "from pathlib import Path;"
            f"time.sleep({idle_first!r});"
            "began = time.monotonic();"
            f"print('RETURNED', m['wait_for_marker'](Path({str(marker)!r}),"
            " 'test'));"
            "print('WAITED %.1f' % (time.monotonic() - began))"
        )
        env = dict(os.environ)
        # Budgets short enough to run here, and above the helper's own floor:
        # each wait may take 5 s, and the ceiling leaves 20 s of speaking room.
        env["KERNEL_QEMU_TIMEOUT"] = "15"
        env["KERNEL_QEMU_CEILING"] = "30"
        started = time.monotonic()
        out = subprocess.run([sys.executable, "-c", probe], env=env,
                             capture_output=True, text=True)
        return out.stdout + out.stderr, time.monotonic() - started


def main() -> int:
    # Every shell consumer must wire both ends of the readiness protocol.
    # Exercising only the peer missed the lifecycle and rollback runners.
    for runner in (ROOT / "scripts").glob("*.sh"):
        source = runner.read_text(encoding="ascii")
        if '"$REPO_ROOT/scripts/kernel_net_test.py"' not in source:
            continue
        commands = source.replace("\\\n", " ").splitlines()

        def wired(program, flags):
            calls = [line for line in commands
                     if f'"$REPO_ROOT/scripts/{program}"' in line]
            if not calls:
                return None
            return all(flag in line for line in calls for flag in flags)

        if not wired("kernel_net_test.py",
                     ("--init-ready-file", "--network-ready-file",
                      "--uart-progress-file")):
            print(f"FAIL net-readiness control: {runner.name} does not "
                  "wire readiness into kernel_net_test.py")
            return 1
        # The UART end is whatever reads this lane's guest: the ash driver,
        # the DDB lane's driver, or a gdb script -- the uart-wake lane's
        # (GitHub issue #546) and the affinity lane's (issue #9) -- which
        # takes the files from its environment, because `gdb -batch -x`
        # passes no argv to the script it runs. It is recognised by what it
        # is handed rather than by name: an earlier version listed the
        # programs, and refused the DDB lane the day that lane started the
        # peer (CI run 34571244409). Some call other than the peer's must
        # carry both files, and no call may carry only one -- which is the
        # half that still bites, whatever the spelling: a lane that wires one
        # file and forgets the other is refused here.
        pairs = (("--init-listener-file", "--network-ready-file"),
                 ("UART_WAKE_INIT_LISTENER=", "UART_WAKE_NETWORK_READY="),
                 ("AFFINITY_GDB_INIT_LISTENER=",
                  "AFFINITY_GDB_NETWORK_READY="))
        others = [line for line in commands
                  if '"$REPO_ROOT/scripts/kernel_net_test.py"' not in line]
        whole = [line for line in others
                 if any(all(flag in line for flag in pair) for pair in pairs)]
        partial = [line for line in others
                   if any(any(flag in line for flag in pair) and
                          not all(flag in line for flag in pair)
                          for pair in pairs)]
        if not whole or partial:
            print(f"FAIL net-readiness control: {runner.name} does not "
                  "hand both readiness files to its UART end")
            return 1
    # 0. Protocol retries must start only after the kernel link is ready, and
    # the init socket exchange must wait for its own later listener. Otherwise
    # a slow guest spends a bounded retry budget on boot rather than traffic.
    with patch.object(sys, "argv", [str(PEER), "--network-ready-file",
                                    "network.ready", "--init-ready-file",
                                    "init.ready"]):
        peer = runpy.run_path(str(PEER), run_name="not_main")
    namespace = peer["main"].__globals__
    for missing in ("network.ready", "init.ready"):
        seen = set()

        def wait(marker, label):
            seen.add(str(marker))
            return str(marker) != missing

        def probe(*args):
            assert "network.ready" in seen
            assert missing != "network.ready"
            return True

        exchange = Mock(side_effect=AssertionError(
            "init exchange started without its listener"))
        replacements = {name: probe for name in (
            "send_until_reply", "test_syn_wrong_port_silent",
            "test_syn_bad_checksum_silent", "do_handshake",
            "test_data_echo", "test_close")}
        replacements.update(wait_for_marker=wait, init_script_fixture=exchange)
        with patch.dict(namespace, replacements), \
                patch.object(namespace["socket"], "socket", return_value=Mock()), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            result = peer["main"]()
        if result != 1 or missing not in seen or exchange.called:
            print("FAIL net-readiness control: missing readiness did not "
                  "stop its exchange")
            return 1
        if "never announced" not in output.getvalue():
            print("FAIL net-readiness control: missing readiness was silent")
            return 1

    # 1. The budget leaves room to speak, for every outer budget in use.
    for budgets in OUTER_BUDGETS:
        outer = budgets[1]
        info = load(budgets)
        if info is None:
            return 1
        if info["outer"] != outer:
            print(f"FAIL net-readiness control: the peer read the outer "
                  f"budget as {info['outer']}, not {outer}")
            return 1
        if info["budget"] >= outer:
            print(f"FAIL net-readiness control: with a {outer:.0f}s outer "
                  f"budget the marker wait runs {info['budget']:.0f}s, so "
                  f"`timeout` kills it before it can say what was missing. "
                  f"This is the defect the interactive wait had.")
            return 1

    # 2. The default must match the shells' own `${KERNEL_QEMU_CEILING:-270}`
    # in every runner that kills the peer with it. A disagreement puts the
    # deadline back on the wrong side of the kill for exactly the runs nobody
    # set the variable for.
    unset = load(None)
    if unset is None:
        return 1
    for runner in ("run_kernel_qemutest.sh",
                   "run_kernel_alloc_rollback_qemutest.sh"):
        shell_default = None
        for line in (ROOT / "scripts" / runner).read_text(
                encoding="ascii").splitlines():
            if line.startswith("CEILING_SECS="):
                shell_default = float(
                    line.split(":-", 1)[1].split("}", 1)[0])
        if shell_default is None:
            print(f"FAIL net-readiness control: {runner} no longer declares "
                  "CEILING_SECS, so its default cannot be compared")
            return 1
        if unset["outer"] != shell_default:
            print(f"FAIL net-readiness control: with KERNEL_QEMU_CEILING "
                  f"unset the peer assumes {unset['outer']:.0f}s and "
                  f"{runner} uses {shell_default:.0f}s")
            return 1

    # 3. A marker that is already there returns at once and prints nothing.
    output, elapsed = timed_wait(0)
    if "RETURNED True" not in output:
        print(f"FAIL net-readiness control: a marker that exists was not "
              f"seen\n{output}")
        return 1
    if elapsed > 5.0:
        print(f"FAIL net-readiness control: a marker that exists took "
              f"{elapsed:.1f}s")
        return 1
    if "never arrived" in output:
        print(f"FAIL net-readiness control: a marker that exists reported a "
              f"give-up\n{output}")
        return 1

    # 4. A marker that never arrives gives up, says so with numbers, and is
    # still inside the outer budget it was told about.
    output, elapsed = timed_wait(None)
    if "RETURNED False" not in output:
        print(f"FAIL net-readiness control: a marker that never arrives did "
              f"not return False\n{output}")
        return 1
    if "never arrived" not in output:
        print(f"FAIL net-readiness control: the give-up printed no line "
              f"naming the marker\n{output}")
        return 1
    if elapsed >= 30.0:
        print(f"FAIL net-readiness control: the give-up took {elapsed:.1f}s "
              f"against a 30s ceiling, so `timeout` would have killed "
              f"it first\n{output}")
        return 1

    # 5. GitHub issue #620: a wait's budget counts from when that wait
    # starts. A peer that spent 12 s on earlier phases -- a slow boot -- must
    # still give this wait its full 5 s, which the old budget from the
    # process's start (15 - 10) had already spent.
    output, elapsed = timed_wait(None, idle_first=12.0)
    waited = next((float(line.split()[1]) for line in output.splitlines()
                   if line.startswith("WAITED ")), 0.0)
    if "RETURNED False" not in output or waited < 4.5:
        print(f"FAIL net-readiness control: after 12 s of earlier phases the "
              f"wait gave up after {waited:.1f}s, not its own 5 s: the "
              f"budget is still counted from the process's start\n{output}")
        return 1

    # 6. And near the ceiling the wait still gives up in time to speak: 25 s
    # in, with a 30 s ceiling and 10 s of safety, it has no time left at all.
    output, elapsed = timed_wait(None, idle_first=25.0)
    if "RETURNED False" not in output or elapsed >= 30.0:
        print(f"FAIL net-readiness control: a wait begun near the ceiling "
              f"ran to {elapsed:.1f}s against a 30s ceiling\n{output}")
        return 1

    from pass_line import report_pass
    report_pass("net-readiness controls",
                "network probes and the init exchange wait for their own "
                "readiness markers, marker waits "
                "give up inside every outer budget the lanes "
                "use, agrees with the shells' own default, returns at once "
                "for a marker that is there, names the one that never "
                "arrives, and counts its budget from its own start (#620)",
                outer_budgets=len(OUTER_BUDGETS), waits_exercised=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.exit(main())
