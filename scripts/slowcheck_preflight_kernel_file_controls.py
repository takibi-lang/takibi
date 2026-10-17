#!/usr/bin/env python3
"""Controls for scripts/preflight_kernel_file.py (GitHub issue #721).

A copy of the tracked kernel, scripts and Makefile is planted with a new
kernel file, a rename, a new assembly file and a new lane runner, each
missing the registry rows a real one needs. The preflight must name every
registry for each, and must report an unchanged file as clean.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CASES = CaseCount()

NEW_TKB = """// A planted file with mutable state and no limitations section.
private let mut planted_state: usize;

fn planted_read() -> usize {
    return planted_state;
}
"""

NEW_ASM = """    .text
planted_entry:
    bl planted_takibi_target
    ret
"""

NEW_RUNNER = """#!/usr/bin/env bash
# A planted lane runner with no artifact directory and no Makefile recipe.
echo planted
"""


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)


def copy_tree(dest: Path) -> None:
    listed = subprocess.run(["git", "ls-files", "-z", "--", "kernel", "scripts",
                             "Makefile"], cwd=ROOT, check=True,
                            capture_output=True).stdout.split(b"\0")
    for raw in listed:
        if not raw:
            continue
        rel = raw.decode()
        source = ROOT / rel
        if not source.is_file():
            continue
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    # The preflight under test is the working copy, tracked or not.
    for name in ("preflight_kernel_file.py",):
        shutil.copyfile(ROOT / "scripts" / name, dest / "scripts" / name)
    git(dest, "init", "-q")
    git(dest, "add", "-A")
    git(dest, "-c", "user.name=control", "-c", "user.email=control@invalid",
        "commit", "-q", "-m", "base")


def preflight(root: Path, *args: str) -> tuple[int, str]:
    CASES.note()
    result = subprocess.run(
        [sys.executable, str(root / "scripts" / "preflight_kernel_file.py"),
         "--root", str(root), *args],
        cwd=root, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def expect(output: str, status: int, want_status: int, needles: list[str],
           label: str) -> None:
    if status != want_status:
        raise SystemExit(f"FAIL preflight-kernel-file controls: {label}: "
                         f"exit {status}, wanted {want_status}\n{output}")
    for needle in needles:
        if needle not in output:
            raise SystemExit(f"FAIL preflight-kernel-file controls: {label}: "
                             f"no line with {needle!r}\n{output}")


def main() -> int:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        copy_tree(root)

        status, output = preflight(root, "kernel/kernel/protocol_trace.tkb")
        expect(output, status, 0, ["0 missing or stale"], "an unchanged file")

        (root / "kernel/kernel/planted.tkb").write_text(NEW_TKB)
        status, output = preflight(root, "kernel/kernel/planted.tkb")
        expect(output, status, 1, [
            "MISSING  check_execution_model_coverage.py",
            "MISSING  check_kernel_lib_limitations_header.py",
            "MISSING  Makefile: in no KERNEL_UNUSED_* list",
        ], "a new kernel file")

        git(root, "mv", "kernel/kernel/protocol_trace.tkb",
            "kernel/kernel/protocol_renamed.tkb")
        status, output = preflight(
            root, "kernel/kernel/protocol_trace.tkb=kernel/kernel/protocol_renamed.tkb")
        expect(output, status, 1, [
            "MISSING  check_execution_model_coverage.py",
            "MISSING  Makefile: in no KERNEL_UNUSED_* list",
            "STALE    Makefile:",
            "STALE    kernel/kernel/process.tkb:",
        ], "a renamed kernel file")
        git(root, "mv", "kernel/kernel/protocol_renamed.tkb",
            "kernel/kernel/protocol_trace.tkb")

        (root / "kernel/arch/arm64/kernel/planted.S").write_text(NEW_ASM)
        (root / "kernel/kernel/planted.tkb").write_text(
            NEW_TKB + "\nfn planted_takibi_target() {\n}\n")
        status, output = preflight(root, "kernel/arch/arm64/kernel/planted.S")
        expect(output, status, 1, ["MISSING  check_kernel_asm_entries.py"],
               "a new assembly file")

        (root / "scripts/run_kernel_planted_qemutest.sh").write_text(NEW_RUNNER)
        status, output = preflight(root, "scripts/run_kernel_planted_qemutest.sh")
        expect(output, status, 1, [
            "MISSING  check_lane_artifact_root.py",
            "MISSING  Makefile: no recipe runs it",
        ], "a new lane runner")

    report_pass("preflight-kernel-file controls",
                "a new kernel file, a rename, a new assembly file and a new "
                "lane runner each have every missing registry named; an "
                "unchanged file reports clean", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
