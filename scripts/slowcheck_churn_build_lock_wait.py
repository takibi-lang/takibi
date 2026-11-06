#!/usr/bin/env python3
"""The churn driver's boot deadline does not count the build-lock wait (#1402).

GitHub issue #1401: scripts/run_kernel_churn.py started its shell-readiness
deadline when it spawned `make kernelsh-qemu`, whose make first waits for
the kernel build lock; under allcheck another lane held it past the
deadline and race-window 633 failed "the shell never became ready". The
driver now times readiness from the runner's launch notice.

This runs the real driver against a stand-in `make` on PATH, with its
deadlines shortened (boot 2 s, prelaunch 8 s) and its vCPU lease stubbed,
so no QEMU starts. Three cases:

- the stand-in "waits for the lock" 4 s, twice the boot deadline, then
  prints the launch notice and the shell's readiness line: the driver must
  get past readiness (whatever fails after it is not this check's);
- it prints the notice and only then waits 4 s for readiness: the boot
  deadline must still fire ("the shell never became ready");
- it never prints the notice: the prelaunch bound must fire.

slowcheck rather than a fast-lane member: it waits on a pty and real time.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]

DRIVER = """
import sys
sys.path.insert(0, {scripts!r})
sys.argv = ["run_kernel_churn.py", "--platform", "qemu", "--rounds", "1",
            "--no-trace", "--stall-seconds", "1"]
import run_kernel_churn as churn
churn.BOOT_TIMEOUT_SECONDS = {{"qemu": 2, "rpi5": 2}}
churn.PRELAUNCH_TIMEOUT_SECONDS = 8
churn.lease = lambda *args, **kwargs: None
sys.exit(churn.main())
"""

FAKE_MAKE = """#!/usr/bin/env bash
# Stand-in for `make -j1 kernelsh-qemu` (scripts/slowcheck_churn_build_lock_wait.py).
echo "WAIT kernel build: another make owns kernel/build (stand-in)" >&2
sleep {before}
{notice}
sleep {after}
echo "interactive shell: uart blocked"
sleep 20
"""


def run(work: pathlib.Path, name: str, before: float, after: float,
        notice: bool) -> str:
    bin_dir = work / name / "bin"
    bin_dir.mkdir(parents=True)
    make = bin_dir / "make"
    line = 'echo "[kernel/qemu] interactive UART session (stand-in)"' if notice else ":"
    make.write_text(FAKE_MAKE.format(before=before, after=after, notice=line))
    make.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
               TAKIBI_LANE_ARTIFACT_ROOT=str(work / name / "artifacts"))
    env.pop("TAKIBI_AWAIT_TIMING_DIR", None)
    result = subprocess.run(
        [sys.executable, "-c", DRIVER.format(scripts=str(ROOT / "scripts"))],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    return result.stdout + result.stderr


def main() -> int:
    errors = []
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        slow_lock = run(work, "slow-lock", 4, 0, True)
        if "never became ready" in slow_lock or "never launched" in slow_lock:
            errors.append("a 4 s build-lock wait failed the 2 s boot deadline: "
                          + slow_lock.strip().splitlines()[-1])
        slow_boot = run(work, "slow-boot", 0, 4, True)
        if "the shell never became ready" not in slow_boot:
            errors.append("a 4 s boot after the launch notice passed the 2 s "
                          "boot deadline")
        silent = run(work, "silent", 30, 0, False)
        if "never launched QEMU" not in silent:
            errors.append("a runner that never printed the launch notice was "
                          "not refused by the prelaunch bound")
    if errors:
        for error in errors:
            print(f"ERROR churn-build-lock-wait: {error}")
        print("FAIL churn-build-lock-wait: the churn's boot deadline does not "
              "start at the launch notice")
        return 1
    report_pass("churn-build-lock-wait",
                "a build-lock wait twice the boot deadline is not boot time; "
                "a slow boot after the launch notice and a runner that never "
                "launches are still refused",
                cases=3 - len(errors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
