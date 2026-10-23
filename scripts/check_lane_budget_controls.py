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
        # #927: a QEMU lane's receipt with no lease-wait recording is refused,
        # since its waits would silently count as work.
        cases.note()
        try:
            lane_seconds(directory, frozenset({"a"}))
        except ValueError:
            pass
        else:
            raise AssertionError("a QEMU receipt without vcpu-lease.waits must be refused")
        # The wait is left out, and parallel waits of one lane count once.
        (directory / "a.jsonl").write_text(
            json.dumps({"lane": "a", "start": 100.0, "elapsed": 10.0}) + "\n")
        (directory / "vcpu-lease.waits").write_text("".join(
            json.dumps(w) + "\n" for w in (
                {"lane": "a", "vcpus": 4, "wait_start": 100.0, "granted": 104.0},
                {"lane": "a", "vcpus": 4, "wait_start": 101.0, "granted": 106.0},
                {"lane": "a", "vcpus": 4, "wait_start": 107.0, "granted": None})))
        cases.note()
        assert lane_seconds(directory, frozenset({"a"})) == (6.5, 2), \
            "busy seconds are elapsed less the union of granted waits"
        # Over budget by busy time fails even though no single lane is long.
        cases.note()
        many = "".join(json.dumps({"lane": f"l{i}", "start": 0.0,
                                   "elapsed": LANE_SECONDS_LIMIT / 10}) + "\n"
                       for i in range(11))
        (directory / "c.jsonl").write_text(many)
        assert verdict(1, lane_seconds(directory, frozenset({"a"}))), \
            "busy lane-seconds past the budget fail"
    report_pass("lane-budget controls",
                f"{len(leaves)} leaf lanes read; budget boundaries and "
                f"{cases.ran} shapes behave", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
