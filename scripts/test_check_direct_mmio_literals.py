#!/usr/bin/env python3
"""Positive and negative controls for check_direct_mmio_literals.py."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_direct_mmio_literals.py"


def run(source: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="takibi-mmio-check-") as directory:
        fixture = Path(directory) / "fixture.tkb"
        fixture.write_text(source)
        return subprocess.run(
            ["python3", str(CHECKER), str(fixture)], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def main() -> int:
    safe = run("fn f(base: usize) { let p: *io u32 = "
               "unsafe { (base + 0x100) as *io u32 }; }\n"
               "// unsafe { 0x10000000 as *io u32 }\n")
    if safe.returncode != 0:
        print(safe.stdout, end="")
        return 1
    unsafe = run("fn f() { let p: *io u32 = "
                 "unsafe { (0x10000000 + 0x100) as *io u32 }; }\n")
    if unsafe.returncode == 0 or "direct absolute MMIO" not in unsafe.stdout:
        print("FAIL direct-mmio-literals controls: negative fixture passed")
        print(unsafe.stdout, end="")
        return 1
    print("PASS direct-mmio-literals controls: derived base accepted and "
          "absolute cast rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
