#!/usr/bin/env python3
"""Reject the real old sysinit ordering and missing or duplicated consumers."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
INIT = ROOT / "kernel/tests/ext2/init.sh"


def main():
    text = INIT.read_text(encoding="ascii")
    old_order = text.replace("\n/bin/dmesg\n", "\n/bin/trace-placeholder\n", 1)
    old_order = old_order.replace("\n/bin/protocol-trace\n", "\n/bin/dmesg\n", 1)
    old_order = old_order.replace("\n/bin/trace-placeholder\n", "\n/bin/protocol-trace\n", 1)
    cases = [("repository", text, None),
             ("old ordering", old_order, "boot dmesg must precede protocol-trace")]
    for command in ("/bin/dmesg", "/bin/protocol-trace"):
        cases.append((f"missing {command}", text.replace(f"\n{command}\n", "\n", 1),
                      f"expected one bare {command} command, found 0"))
        cases.append((f"duplicate {command}", text + f"\n{command}\n",
                      f"expected one bare {command} command, found 2"))
        cases.append((f"commented {command}",
                      text.replace(f"\n{command}\n", f"\n# {command}\n", 1),
                      f"expected one bare {command} command, found 0"))
    with tempfile.TemporaryDirectory(prefix="takibi-boot-log-") as directory:
        tree = pathlib.Path(directory)
        (tree / "scripts").mkdir()
        fixture = tree / "kernel/tests/ext2/init.sh"
        fixture.parent.mkdir(parents=True)
        for name in ("check_boot_log_snapshot.py", "pass_line.py"):
            shutil.copy(ROOT / "scripts" / name, tree / "scripts" / name)
        for name, source, diagnostic in cases:
            fixture.write_text(source, encoding="ascii")
            result = subprocess.run(
                [sys.executable, str(tree / "scripts/check_boot_log_snapshot.py")],
                capture_output=True, text=True, check=False)
            output = result.stdout + result.stderr
            if diagnostic is None:
                good = result.returncode == 0 and "PASS boot-log-snapshot:" in output
            else:
                good = result.returncode != 0 and diagnostic in output
            if not good:
                print(f"FAIL boot-log-snapshot controls: {name}: {result.returncode}: {output}")
                return 1
    report_pass("boot-log-snapshot controls",
                "repository passes; old order, missing, duplicate and commented commands fail",
                cases=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
