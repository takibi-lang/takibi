#!/usr/bin/env python3
"""Controls for check_lane_budget.py (#908), in both directions."""

import json
import pathlib
import tempfile

from check_lane_budget import (LANE_SECONDS_LIMIT, MAKEFILE, QEMU_LANE_LIMIT,
                               lane_seconds, qemu_leaf_lanes, verdict)
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
    assert not verdict(1, (LANE_SECONDS_LIMIT, 3)), "exactly the seconds budget passes"
    cases.note()
    assert verdict(1, (LANE_SECONDS_LIMIT + 1, 3)), "past the seconds budget fails"
    cases.note()
    try:
        qemu_leaf_lanes(text.replace("KERNELCHECK_QEMU_LANES :=", "KERNELCHECK_QEMU_LANEZ :="))
    except ValueError:
        pass
    else:
        raise AssertionError("a renamed lane list must be refused, not counted as zero")
    with tempfile.TemporaryDirectory() as tmp:
        directory = pathlib.Path(tmp)
        cases.note()
        assert lane_seconds(directory) is None, "no artifact is not a measurement"
        (directory / "a.jsonl").write_text(json.dumps({"lane": "a", "elapsed": 1.5}) + "\n")
        (directory / "b.jsonl").write_text(json.dumps({"lane": "b", "elapsed": 2.5}) + "\n")
        cases.note()
        assert lane_seconds(directory) == (4.0, 2), "receipts are summed"
    report_pass("lane-budget controls",
                f"{len(leaves)} leaf lanes read; budget boundaries and "
                f"{cases.ran} shapes behave", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
