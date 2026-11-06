#!/usr/bin/env python3
"""Controls for check_lane_budget.py (#908), in both directions."""

import json
import pathlib
import tempfile

from check_lane_budget import (LANE_CPU_SECONDS_LIMIT, MAKEFILE, QEMU_LANE_LIMIT,
                               cpu_shell_gaps, lane_cpu_seconds, qemu_leaf_lanes,
                               verdict)
from check_lane_budget import main as budget_main
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    text = MAKEFILE.read_text(encoding="ascii")
    leaves = qemu_leaf_lanes(text)
    cases.note()
    assert "kernelcheck-qemu-main" in leaves and "kernelcheck-qemu" not in leaves, \
        "an aggregate lane is expanded into its leaves"
    cases.note()
    grown = text.replace("KERNELCHECK_QEMU_LANES := kernelcheck-qemu ",
                         "KERNELCHECK_QEMU_LANES := kernelcheck-qemu kernelcheck-shell-qemu ")
    assert grown != text and len(qemu_leaf_lanes(grown)) == len(leaves) + 1, \
        "a lane added to the list is counted"
    cases.note()
    assert not verdict(QEMU_LANE_LIMIT, None), "exactly the lane budget passes"
    cases.note()
    assert verdict(QEMU_LANE_LIMIT + 1, None), "one lane over fails"
    cases.note()
    assert not verdict(1, (LANE_CPU_SECONDS_LIMIT, 3)), "exactly the seconds budget passes"
    cases.note()
    assert verdict(1, (LANE_CPU_SECONDS_LIMIT + 1, 3)), "past the seconds budget fails"
    cases.note()
    try:
        qemu_leaf_lanes(text.replace("KERNELCHECK_QEMU_LANES :=", "KERNELCHECK_QEMU_LANEZ :="))
    except ValueError:
        pass
    else:
        raise AssertionError("a renamed lane list must be refused, not counted as zero")
    # #1198: every lane timed by begin/end gets the CPU-taking shell.
    cases.note()
    assert not cpu_shell_gaps(text), "every begin/end lane takes its CPU"
    cases.note()
    assert cpu_shell_gaps(text.replace("LANE_CPU_SHELL_LANES := langcheck ",
                                       "LANE_CPU_SHELL_LANES := ")) == ["langcheck"], \
        "a begin/end lane left off the CPU shell list is named"
    with tempfile.TemporaryDirectory() as tmp:
        directory = pathlib.Path(tmp)
        cases.note()
        assert lane_cpu_seconds(directory) is None, "no artifact is not a measurement"
        (directory / "a.jsonl").write_text(
            json.dumps({"lane": "a", "elapsed": 90.0, "cpu": 1.5}) + "\n")
        (directory / "b.jsonl").write_text(
            json.dumps({"lane": "b", "elapsed": 1.0, "cpu": 2.5}) + "\n")
        cases.note()
        assert lane_cpu_seconds(directory) == (4.0, 2), \
            "CPU is summed, not elapsed time"
        # A receipt without CPU (pre-#1198, or a lane whose CPU was not
        # taken) is refused, since leaving it out would sum low.
        (directory / "c.jsonl").write_text(json.dumps({"lane": "c", "elapsed": 1.0}) + "\n")
        cases.note()
        try:
            lane_cpu_seconds(directory)
        except ValueError:
            pass
        else:
            raise AssertionError("a receipt without cpu must be refused")
        # Over budget by CPU fails even though no single lane is long.
        cases.note()
        many = "".join(json.dumps({"lane": f"l{i}", "start": 0.0, "elapsed": 1.0,
                                   "cpu": LANE_CPU_SECONDS_LIMIT / 10 + 1}) + "\n"
                       for i in range(11))
        (directory / "c.jsonl").write_text(many)
        assert verdict(1, lane_cpu_seconds(directory)), \
            "CPU seconds past the budget fail"
    # #1123: only the kept green copy is measured. A red run over the budget
    # in _build/lane-timing does not refuse the next land; a green run over
    # the budget, once kept, does.
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        red, green_run, kept = root / "red", root / "green", root / "git" / "kept"
        for directory, cpu in ((red, LANE_CPU_SECONDS_LIMIT * 3 + 1), (green_run, 0.0)):
            directory.mkdir()
            (directory / "x.jsonl").write_text(
                json.dumps({"lane": "x", "elapsed": 10.0, "cpu": cpu}) + "\n")
        cases.note()
        assert budget_main([str(kept)]) == 0, "no kept green copy yet passes"
        assert budget_main(["--keep-green", str(green_run), str(kept)]) == 0
        cases.note()
        assert budget_main([str(kept)]) == 0, "a green run within budget passes"
        cases.note()
        assert budget_main([str(red)]) == 1 and budget_main([str(kept)]) == 0, \
            "a red run's receipts are over budget but not the kept copy"
        cases.note()
        assert budget_main(["--keep-green", str(red), str(kept)]) == 0 \
            and budget_main([str(kept)]) == 1, "a green run over the budget still fails"
        # #1193: a lane that began and wrote no receipt (the quiet 5f79f0c0
        # run's langcheck.start) is refused, both when measured and when
        # kept, since the sum would leave its seconds out.
        (green_run / "langcheck.start").write_text("1.0\n")
        cases.note()
        assert budget_main([str(green_run)]) == 1, "an unfinished lane is refused"
        cases.note()
        assert budget_main(["--keep-green", str(green_run), str(kept)]) == 1 \
            and budget_main([str(kept)]) == 1, "an unfinished run is not kept"
        (green_run / "langcheck.start").unlink()
        # #1198: a run with a receipt that carries no CPU is not kept.
        (green_run / "old.jsonl").write_text(json.dumps({"lane": "old", "elapsed": 1.0}) + "\n")
        cases.note()
        assert budget_main(["--keep-green", str(green_run), str(kept)]) == 1, \
            "a run with a receipt that carries no CPU is not kept"
        (green_run / "old.jsonl").unlink()
        cases.note()
        assert not (root / "git" / "kept.new").exists() \
            and not (root / "git" / "kept.old").exists(), "no staging copy is left"
        assert budget_main(["--keep-green", str(root / "absent"), str(kept)]) == 1 \
            and budget_main([str(kept)]) == 1, "a missing source is refused, the copy kept"
    report_pass("lane-budget controls",
                f"{len(leaves)} leaf lanes read; budget boundaries and "
                f"{cases.ran} shapes behave", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
