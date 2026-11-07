#!/usr/bin/env python3
"""Fixed-budget console waits record their arrival against the budget.

GitHub issue #666. kernel/tests/check_fdt_multibank_qemu.py waits a fixed
10 s from each QEMU start for one memory line, and the shell runner
run_kernel_stack_overflow_qemutest.sh waits 100 x 0.1 s for its overflow line
and records it through await_timing.py's command line. These controls drive
the real observe_process with a short-lived child instead of QEMU, and the
real command line, so they check the recording, not a second copy of it: an arrival is recorded with its fraction
of the budget, a late arrival prints the RECORDED margin line without
changing the verdict, and a boot that ends without the line is recorded as
not arrived. GitHub issue #1365: the FDT wait is a no-progress budget, so a
slow guest that keeps printing past 10 s still arrives (the old absolute
deadline cut it off and blamed the seed), silence for the budget ends the wait
as "quiet", and endless output stops at the cap. The aggregate destination inherited from an enclosing allcheck
is removed first, so these synthetic waits never join a real summary.

Exit code only (0 = pass, 1 = fail).
"""

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
DRIVER = ROOT / "kernel/tests/check_fdt_multibank_qemu.py"


def load_driver():
    spec = importlib.util.spec_from_file_location("fdt_multibank", DRIVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def child(text):
    return subprocess.Popen(
        [sys.executable, "-c", f"import sys; sys.stdout.write({text!r})"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def main() -> int:
    for name in ("TAKIBI_AWAIT_TIMING_DIR", "TAKIBI_AWAIT_TIMING_LANE"):
        os.environ.pop(name, None)
    driver = load_driver()
    problems = []
    cases = 0
    with tempfile.TemporaryDirectory(prefix="takibi-fdt-await-") as directory:
        base = pathlib.Path(directory)

        arrived = base / "arrived.jsonl"
        found, _ = driver.observe_process(child("boot\nSYNTHETIC-ARRIVAL\n"),
                                          b"SYNTHETIC-ARRIVAL", str(arrived), "line")
        row = rows(arrived)
        cases += 1
        if not found or len(row) != 1 or row[0]["status"] != "arrived" \
                or row[0]["timeout_seconds"] != driver.OBSERVE_TIMEOUT_SECONDS \
                or not 0 <= row[0]["fraction"] < 0.5:
            problems.append(f"an arrival was not recorded as one fraction: {row}")

        # Six seconds of the ten pass between the start and the arrival.
        times = iter([0.0, 0.0, 0.0])
        late = base / "late.jsonl"
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            found, _ = driver.observe_process(
                child("SYNTHETIC-ARRIVAL\n"), b"SYNTHETIC-ARRIVAL", str(late), "line",
                clock=lambda: next(times, 6.0))
        row = rows(late)
        cases += 1
        if not found or row[0]["fraction"] != 0.6:
            problems.append(f"a late arrival changed the verdict or fraction: {row}")
        if "RECORDED kernel/qemu fdt-multibank await margin" not in printed.getvalue():
            problems.append("an arrival past half the budget printed no margin line")

        missing = base / "missing.jsonl"
        found, _ = driver.observe_process(child("boot\n"), b"SYNTHETIC-ARRIVAL",
                                          str(missing), "line")
        row = rows(missing)
        cases += 1
        if found or len(row) != 1 or row[0]["status"] != "not-arrived" \
                or row[0]["fraction"] is not None:
            problems.append(f"a missing line was not recorded as not arrived: {row}")

        # GitHub issue #1365: a slow guest that keeps printing arrives past
        # the 10 s mark; each output restarts the quiet budget, so this is an
        # arrival, where the old absolute deadline cut it off. The fake clock
        # moves 3 s per reading, so the arrival lands far past 10 s.
        ticks = [0.0]
        def slow_clock():
            ticks[0] += 3.0
            return ticks[0]
        slow = base / "slow.jsonl"
        with contextlib.redirect_stdout(io.StringIO()):
            found, _ = driver.observe_process(
                subprocess.Popen(
                    [sys.executable, "-c",
                     "import sys, time\n"
                     "for _ in range(6):\n"
                     "    sys.stdout.write('tick\\n'); sys.stdout.flush(); time.sleep(0.1)\n"
                     "sys.stdout.write('SYNTHETIC-ARRIVAL\\n')"],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT),
                b"SYNTHETIC-ARRIVAL", str(slow), "line", clock=slow_clock)
        row = rows(slow)
        cases += 1
        if not found or driver.last_end != "arrived" or not row[0]["fraction"] > 1.0:
            problems.append("a guest still printing past the quiet budget was cut "
                            f"off (the #1365 shape): found={found} "
                            f"end={driver.last_end} {row}")

        # Silence for the budget ends the wait, and the failure line says so
        # instead of blaming what the missing line would have shown.
        times = iter([0.0, 0.0, 0.0])
        quiet = base / "quiet.jsonl"
        found, _ = driver.observe_process(
            subprocess.Popen([sys.executable, "-c",
                              "import sys, time; sys.stdout.write('boot\\n'); "
                              "sys.stdout.flush(); time.sleep(2)"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT),
            b"SYNTHETIC-ARRIVAL", str(quiet), "line",
            clock=lambda: next(times, 11.0))
        cases += 1
        if found or driver.last_end != "quiet" or "no output" not in driver.wait_note():
            problems.append(f"a silent guest did not end as quiet: {driver.last_end} "
                            f"{driver.wait_note()!r}")

        # A guest printing forever stops at the cap.
        times = iter([0.0, 0.0, 0.0])
        capped = base / "capped.jsonl"
        found, _ = driver.observe_process(
            subprocess.Popen([sys.executable, "-c",
                              "import sys, time\n"
                              "while True:\n"
                              "    sys.stdout.write('tick\\n'); sys.stdout.flush(); time.sleep(0.05)"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT),
            b"SYNTHETIC-ARRIVAL", str(capped), "line",
            clock=lambda: next(times, driver.OBSERVE_CAP_SECONDS + 1.0))
        cases += 1
        if found or driver.last_end != "cap" or "cap" not in driver.wait_note():
            problems.append(f"an endless guest did not stop at the cap: {driver.last_end}")
        # GitHub issue #1415: the stack-overflow runner's wait
        # (await_log_line.py) is a no-progress budget too. A fake clock moves
        # 1 s per sleep and each sleep appends a line; the report lands at
        # 15 s, which the old 100 x 0.1 s loop cut off.
        spec = importlib.util.spec_from_file_location(
            "await_log_line", ROOT / "scripts/await_log_line.py")
        awaiter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(awaiter)
        log = base / "uart.log"
        fake = [0.0]

        def growing(arrive_at, endless=False):
            log.write_text("boot\n")
            fake[0] = 0.0

            def sleep(_):
                fake[0] += 1.0
                with log.open("a") as f:
                    if not endless and fake[0] >= arrive_at:
                        f.write("kernel stack: OVERFLOW at exception entry\n")
                    else:
                        f.write("tick\n")
            return sleep

        arrived, reason = awaiter.wait(
            log, "kernel stack: OVERFLOW", 10.0, 180.0,
            clock=lambda: fake[0], sleep=growing(15.0))
        cases += 1
        if not arrived:
            problems.append(f"the overflow wait cut off a guest still printing at 15 s: {reason}")

        log.write_text("boot\n")
        fake[0] = 0.0

        def still(_):
            fake[0] += 1.0
        arrived, reason = awaiter.wait(log, "kernel stack: OVERFLOW", 10.0, 180.0,
                                       clock=lambda: fake[0], sleep=still)
        cases += 1
        if arrived or "no output for 10 s" != reason:
            problems.append(f"a silent log did not end as quiet: {reason}")

        arrived, reason = awaiter.wait(
            log, "kernel stack: OVERFLOW", 10.0, 180.0,
            clock=lambda: fake[0], sleep=growing(0.0, endless=True))
        cases += 1
        if arrived or "cap" not in reason:
            problems.append(f"an endless log did not stop at the cap: {reason}")

        # The shell runner's command line: same rows, same margin line.
        for arrived_flag, ended, status, fraction in (
                (["--arrived"], 1.0, "arrived", 0.1),
                (["--arrived"], 7.0, "arrived", 0.7),
                ([], 10.0, "not-arrived", None)):
            path = base / f"cli-{status}-{ended}.jsonl"
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/await_timing.py"),
                 "--path", str(path), "--label", "kernel/qemu stack-overflow",
                 "--origin", "control", "--name", "overflow line",
                 "--timeout", "10", "--started", "0", "--ended", str(ended)]
                + arrived_flag, capture_output=True, text=True)
            row = rows(path)
            cases += 1
            if result.returncode != 0 or len(row) != 1 \
                    or row[0]["status"] != status \
                    or row[0]["fraction"] != fraction:
                problems.append(f"command line {status} at {ended}: {row}")
            flagged = "RECORDED kernel/qemu stack-overflow await margin" in result.stdout
            if flagged != (fraction is not None and fraction > 0.5):
                problems.append(f"command line margin line wrong at {ended}: "
                                f"{result.stdout!r}")

    for problem in problems:
        print(f"FAIL fixed-wait await controls: {problem}")
    if problems:
        return 1
    report_pass("fixed-wait await controls",
                "the FDT boots and the stack-overflow runner's command line "
                "record each arrival's fraction of its fixed budget, print the "
                "margin past half without changing the verdict, and record a "
                "missing line as not arrived", cases=cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())
