#!/usr/bin/env python3
"""Controls for the platform-parity check, both halves of it.

The check refuses two shapes of the same defect, and the repository passes
today, so a control that only ran it would prove neither. Each rule is
exercised against a planted copy of the tree instead.

The shapes are #470's and #517's. #470 was a formatter defined in both
platform trees whose copies diverged and cost two instrumented hardware boots;
the check answers it by comparing FUNCTIONS. #517 is the same failure written
inline -- a 57-line probe sequence sat byte-identical in both platform
`init.tkb` files while the check said PASS, because a block inside `main()` is
not a function. The second rule answers that by comparing runs.

The threshold is the interesting part to control. It is measured in
significant lines rather than raw ones, because the longest raw run between
the two entry files is thirteen closing braces, and nothing can make those
drift. So the cases below plant a run that is long in raw lines and short in
significant ones, and require it NOT to fire.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_platform_file_parity.py"
PLATFORMS = ("kernel/platform/qemu", "kernel/platform/rpi5")

# Eight significant BODY lines: the threshold exactly, so a passing control
# proves the boundary rather than something well past it. The name differs per
# platform on purpose -- an identically named function would be claimed by the
# function rule first, and this case is about the run rule.
PLANTED_RUN = """
fn planted_parity_probe_NAME() -> usize {
    let a: usize = 1;
    let b: usize = 2;
    let c: usize = 3;
    let d: usize = 4;
    let e: usize = 5;
    let f: usize = 6;
    let g: usize = 7;
    return a + b + c + d + e + f + g;
}
"""

# The same length in raw lines, but only two of them significant. This is the
# shape raw-line counting gets wrong, and it must stay quiet.
PLANTED_PUNCTUATION = """
fn planted_parity_braces_NAME() -> usize {
    let value: usize = 1;
    if (value == 1) {
        if (value == 1) {
            if (value == 1) {
            }
        }
    }
    return value;
}
"""


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


def case(name, plant, want, should_fail=True):
    """Copy what the check reads, plant one defect, and require the verdict."""
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        (root / "scripts").mkdir(parents=True)
        for script in ("check_platform_file_parity.py", "pass_line.py"):
            shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
        for platform in PLATFORMS:
            shutil.copytree(REPO / platform, root / platform)
        plant(root)
        status, report = run(root)
        if should_fail and status == 0:
            failures.append(f"{name}: the planted defect passed")
        elif not should_fail and status != 0:
            failures.append(f"{name}: a legitimate tree was refused: "
                            f"{report.strip()!r}")
        elif want and want not in report:
            failures.append(f"{name}: reported {report.strip()!r}, which does "
                            f"not name {want!r}")
    return failures


def append_to_both(text, filename="init.tkb"):
    """Append the same block to both trees, fenced so it stands alone.

    The fence matters: these files already END in a short shared run, and an
    unfenced block would merge with it and be measured as one longer run. A
    control that plants eight lines has to be measuring eight.
    """
    def plant(root):
        for platform in PLATFORMS:
            target = root / platform / filename
            fence = f"\n// planted fence {platform}\n"
            body = text.replace("NAME", platform.rsplit("/", 1)[1])
            target.write_text(target.read_text() + fence + body + fence,
                              encoding="ascii")
    return plant


def diverge_a_function(root):
    """#470's own shape: one copy of a shared body edited, the other not."""
    target = root / PLATFORMS[0] / "uart.tkb"
    text = target.read_text(encoding="ascii")
    target.write_text(text + "\nfn planted_only_here() -> usize {\n"
                      "    return 1;\n}\n", encoding="ascii")
    other = root / PLATFORMS[1] / "uart.tkb"
    other.write_text(other.read_text(encoding="ascii") +
                     "\nfn planted_only_here() -> usize {\n"
                     "    return 1;\n}\n", encoding="ascii")


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "no undeclared inline run" not in report:
        failures.append(f"the repository passed without reporting the run "
                        f"comparison at all: {report.strip()!r}")

    failures += case(
        "inline run", append_to_both(PLANTED_RUN),
        "8 significant lines duplicated in every platform tree")

    failures += case(
        "punctuation is not duplication",
        append_to_both(PLANTED_PUNCTUATION), "", should_fail=False)

    failures += case(
        "identical function", diverge_a_function,
        "planted_only_here")

    # The run rule must not report what the function rule has already put in
    # front of a reviewer, or the declaration would look ineffective and the
    # next person would widen it rather than read it.
    def plant_in_allowed(root):
        target = root / PLATFORMS[0] / "memory.tkb"
        text = target.read_text(encoding="ascii")
        target.write_text(text.replace(
            "fn platform_memory_detect() -> PlatformMemoryResult !{unsafe} {",
            "fn platform_memory_detect() -> PlatformMemoryResult !{unsafe} {\n"
            "    let planted_a: usize = 1;\n    let planted_b: usize = 2;\n"
            "    let planted_c: usize = 3;\n    let planted_d: usize = 4;\n"
            "    let planted_e: usize = 5;\n    let planted_f: usize = 6;\n"
            "    let planted_g: usize = 7;\n    let planted_h: usize = 8;",
            1), encoding="ascii")
        other = root / PLATFORMS[1] / "memory.tkb"
        text = other.read_text(encoding="ascii")
        other.write_text(text.replace(
            "fn platform_memory_detect() -> PlatformMemoryResult !{unsafe} {",
            "fn platform_memory_detect() -> PlatformMemoryResult !{unsafe} {\n"
            "    let planted_a: usize = 1;\n    let planted_b: usize = 2;\n"
            "    let planted_c: usize = 3;\n    let planted_d: usize = 4;\n"
            "    let planted_e: usize = 5;\n    let planted_f: usize = 6;\n"
            "    let planted_g: usize = 7;\n    let planted_h: usize = 8;",
            1), encoding="ascii")

    failures += case("declared function is not reported twice",
                     plant_in_allowed, "", should_fail=False)

    # A declaration outliving the duplication it describes is the way an
    # exemption list rots: every remaining entry reads as current.
    def plant_stale_declaration(root):
        target = root / "scripts" / "check_platform_file_parity.py"
        text = target.read_text(encoding="ascii")
        target.write_text(text.replace(
            "ALLOWED_RUNS = {",
            'ALLOWED_RUNS = {\n    ("init.tkb", "planted stale declaration"):\n'
            '        "describes duplication that does not exist",',
            1), encoding="ascii")

    failures += case("stale declaration", plant_stale_declaration,
                     "planted stale declaration")

    for failure in failures:
        print(f"ERROR\tplatform-parity-controls: {failure}")
    if failures:
        print("FAIL platform-parity controls: the check does not refuse code "
              "that can drift between the platform trees")
        return 1
    print("PASS platform-parity controls: the repository passes, a duplicated "
          "function and a duplicated inline run of the threshold length are "
          "each refused, a run that is long only in punctuation is not, and a "
          "run inside an already-declared function is not reported twice, "
          "and a declaration that outlives its subject is refused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
