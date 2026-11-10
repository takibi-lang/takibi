#!/usr/bin/env python3
"""Exercise the real model runner's shared queue and trace verdicts offline.

Fake trace commands stand in for TLC; the production shell queue and verdict
blocks execute unchanged. No solver, kernel, network or external wait is used.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from pass_line import report_pass

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    source = (ROOT / "scripts/run_model_checks.sh").read_text()
    queue = source.split("# Trace controls share", 1)[1].split(
        "# Each job is one line:", 1)[0]
    run = source.split("# Run. A job", 1)[1].split("failures=0", 1)[0]
    # The first line in each selected block is the remainder of its comment.
    queue = queue.split("\n", 1)[1]
    run = run.split("\n", 1)[1]
    judge = "failures=0" + source.split("failures=0", 1)[1].split(
        "for model in ", 1)[0]
    cases = [
        ("pass", "", True),
        ("serial", "", True),
        ("nonzero", "", False),
        ("counterexample", "", False),
        ("no-pass", "", False),
        ("pass", 'rm "$TRACE_CONTROLS_LOG"', False),
        ("pass", 'rm "$TRACE_CONTROLS_LOG.exit"', False),
        ("pass", 'printf "12\\n" >"$RING_TRACE_CONTROLS_LOG.exit"', False),
        ("missing-command", "", False),
    ]
    with tempfile.TemporaryDirectory(prefix="takibi-model-queue-") as tmp:
        root = Path(tmp)
        (root / "scripts").mkdir()
        (root / "out").mkdir()
        fake = r'''import os, sys, fcntl
from pathlib import Path
def event(kind):
    with open(os.environ["OUT"] + "/events", "a") as out:
        fcntl.flock(out, fcntl.LOCK_EX)
        out.write(kind + " " + str(os.getpid()) + "\n")
event("start")
# Bounded CPU work permits overlap without a timing-dependent verdict.
for _ in range(10000):
    pass
event("end")
if Path(sys.argv[0]).name == "negative.py":
    sys.exit(12)
assert os.environ["MODELCHECK_JOBS"] == "1"
mode = os.environ["CONTROL_MODE"]
if mode == "nonzero":
    print("PASS fake before failure")
    sys.exit(7)
if mode == "counterexample":
    print("FAIL planted counterexample")
    sys.exit(1)
if mode == "no-pass":
    sys.exit(0)
print("PASS fake control")
'''
        for name in ("protocol_trace_tlc_controls.py",
                     "log_ring_trace_tlc_controls.py", "negative.py"):
            (root / "scripts" / name).write_text(fake)
        for index, (mode, sabotage, expected) in enumerate(cases):
            # Poison outputs first. A missing command must overwrite the old
            # PASS and record its actual nonzero exit, never reuse success.
            for name in ("protocol-trace-controls", "log-ring-trace-controls"):
                (root / "out" / f"{name}.log").write_text("PASS stale\n")
                (root / "out" / f"{name}.log.exit").write_text("0\n")
            (root / "out" / "events").write_text("")
            env = dict(os.environ, REPO_ROOT=str(root), OUT=str(root / "out"),
                       MODELS=str(root), JOBS="1" if mode == "serial" else "2",
                       CONTROL_MODE=mode)
            # An ordinary faulty variant exits nonzero intentionally; the
            # queue must finish and preserve its exit independently.
            prefix = 'QUEUE="$OUT/jobs.list"\n: >"$QUEUE"\n'
            extra = 'echo "$OUT/negative.log python3 $REPO_ROOT/scripts/negative.py" >>"$QUEUE"\n'
            if mode == "missing-command":
                extra += 'rm "$REPO_ROOT/scripts/protocol_trace_tlc_controls.py"\n'
            script = ("set -euo pipefail\n" + prefix + queue + extra + run
                      + sabotage + "\n" + judge + '\n[ "$failures" -eq 0 ]\n')
            result = subprocess.run(["bash", "-c", script], env=env,
                                    text=True, capture_output=True, timeout=3)
            assert (result.returncode == 0) == expected, (
                index, result.returncode, result.stdout, result.stderr)
            if not expected:
                assert "FAIL modelcheck: the trace TLC controls" in result.stdout, (
                    index, result.stdout, result.stderr)
            assert (root / "out" / "negative.log.exit").read_text() == "12\n"
            queued = (root / "out" / "jobs.list").read_text().splitlines()
            assert len(queued) == 3
            assert "protocol_trace_tlc_controls.py" in queued[0]
            assert "log_ring_trace_tlc_controls.py" in queued[1]
            assert "negative.log" in queued[2]
            active = set()
            started = set()
            for row in (root / "out" / "events").read_text().splitlines():
                event, pid = row.split()
                if event == "start":
                    active.add(pid)
                    started.add(pid)
                else:
                    active.remove(pid)
                assert len(active) <= int(env["JOBS"])
            assert not active
            assert len(started) == (2 if mode == "missing-command" else 3)
    report_pass("model queue controls",
                "shared trace queue preserves negative-model exits and rejects "
                "failed, missing or stale control results", scenarios=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
