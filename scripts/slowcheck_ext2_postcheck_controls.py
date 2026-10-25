#!/usr/bin/env python3
"""Controls for scripts/ext2_postcheck.py (GitHub issue #1033).

Every lane's disk passes today, so a postcheck that only ran on lane disks
would prove nothing about the failures it exists for. Each case here builds
a small ext2 image with mke2fs and debugfs, plants one defect, and requires
the postcheck to refuse it with the reason named: a group descriptor and a
superblock counter moved apart from the bitmaps (the leak and double-free
shape of #1020 / #1021), a capacity line the superblock does not back, a
presence fact that does not hold, and a known divergence that no longer
shows -- the row a fix must flip. Slow lane: it runs e2fsprogs.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

from check_ext2_postcheck_lanes import problems as lane_problems
from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
POSTCHECK = REPO / "scripts/ext2_postcheck.py"
CASES = CaseCount()


def debugfs(image, *commands):
    for command in commands:
        subprocess.run(["debugfs", "-w", "-R", command, str(image)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True)


def fresh(work, name):
    image = work / f"{name}.img"
    with open(image, "wb") as handle:
        handle.truncate(1024 * 1024)
    subprocess.run(["mke2fs", "-q", "-t", "ext2", "-b", "1024", "-I", "128",
                    "-N", "64", "-O", "none", "-F", str(image), "1024"],
                   env={**os.environ, "E2FSPROGS_FAKE_TIME": "1700000000"},
                   stdout=subprocess.DEVNULL, check=True)
    debugfs(image, "mkdir /etc", "mkdir /kept")
    return image


def postcheck(work, name, image, *extra):
    CASES.note()
    finished = subprocess.run(
        [sys.executable, str(POSTCHECK), "--label", name, "--image",
         str(image), "--out", str(work / f"{name}.out"), *extra],
        capture_output=True, text=True)
    return finished.returncode, finished.stdout + finished.stderr


def main():
    failures = []

    def expect(name, image, want_status, want_text, *extra):
        status, output = postcheck(work, name, image, *extra)
        if status != want_status or want_text not in output:
            failures.append(f"{name}: exit {status}, wanted {want_status} "
                            f"with '{want_text}'; output:\n{output}")

    with tempfile.TemporaryDirectory(prefix="t1033-postcheck-") as name:
        work = pathlib.Path(name)
        clean = fresh(work, "clean")
        expect("clean", clean, 0, "")
        summary = (work / "clean.out/ext2-postcheck.txt").read_text()
        if "#968 /grow: not reached" not in summary:
            failures.append(f"clean: the absent /grow row was not reported "
                            f"as unreached:\n{summary}")

        grown = fresh(work, "grown")
        debugfs(grown, "expand_dir /etc", "mkdir /grow",
                *["expand_dir /grow"] * 3)
        expect("grown", grown, 0, "", "--grown-dir", "/etc", "--dir", "/kept")
        summary = (work / "grown.out/ext2-postcheck.txt").read_text()
        if "#968 /grow: still divergent" not in summary:
            failures.append(f"grown: the direct-only /grow row was not "
                            f"reported as divergent:\n{summary}")

        expect("not-grown", clean, 1, "/etc on the guest's disk is not past "
               "one block", "--grown-dir", "/etc")
        expect("missing-dir", clean, 1, "/moved is not a directory",
               "--dir", "/moved")

        fixed = fresh(work, "fixed")
        debugfs(fixed, "mkdir /grow", *["expand_dir /grow"] * 13)
        expect("divergence-fixed", fixed, 1,
               "#968 /grow: the known divergence no longer shows")

        group = fresh(work, "group")
        debugfs(group, "set_bg 0 free_blocks_count 1")
        expect("group-counter", group, 1, "group 0 free blocks: descriptor 1")

        superblock = fresh(work, "superblock")
        debugfs(superblock, "ssv free_inodes_count 1")
        expect("superblock-counter", superblock, 1,
               "counters disagree: free inodes: superblock 1")

        uart = work / "uart.log"
        uart.write_bytes(b"resource exhausted: ext2 blocks capacity=999\n")
        expect("capacity", clean, 1, "guest printed ext2 blocks capacity=999",
               "--uart-log", str(uart))
        uart.write_bytes(b"resource exhausted: ext2 blocks capacity=1024\n")
        expect("capacity-agrees", clean, 0, "", "--uart-log", str(uart))

        expect("report-only", group, 0, "ext2 postcheck report-only: FAIL",
               "--report-only")
        expect("no-image", work / "absent.img", 1, "no disk image at")

    # The lane check: a writable drive without the postcheck is refused; a
    # read-only drive, a commented one, and a runner that calls it are not.
    drive = '    -drive "file=$IMAGE,if=none,format=raw,id=vd0" \\\n'
    for name, text, want in (
            ("lane-missing", drive, 1),
            ("lane-readonly", drive.replace("raw,", "raw,readonly=on,"), 0),
            ("lane-comment", "# " + drive, 0),
            ("lane-calls", drive + 'python3 scripts/ext2_postcheck.py\n', 0)):
        CASES.note()
        got = len(lane_problems(name, text)[0])
        if got != want:
            failures.append(f"{name}: {got} problems, wanted {want}")

    for failure in failures:
        print(f"ERROR\text2-postcheck-controls: {failure}")
    if failures:
        print("FAIL ext2-postcheck controls")
        return 1
    report_pass(
        "ext2-postcheck controls",
        "a clean disk passes; a descriptor or superblock counter apart from "
        "its bitmap, a capacity line the superblock does not back, an "
        "ungrown or absent directory, a missing image and a known divergence "
        "that no longer shows are each refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
