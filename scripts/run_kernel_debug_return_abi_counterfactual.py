#!/usr/bin/env python3
"""GitHub issue #713: the debug-return lane must fail on a wrong classifier.

Builds the fixture's real production sidecar, rewrites its return_abi the
way a regressed classifier would, and runs the lane with it. The lane must
fail with the specific mismatch at the probe the substitution breaks; exit
status alone is not accepted, because a lane that crashed for another
reason would also exit non-zero.

  direct-classifier: the pre-#693 rule, every scalar leaf in a register,
                     so the nine-leaf result is described as x0..x8.
  c-size-rule:       the C aggregate rule, every result over 16 bytes
                     through x8, so the 32-byte four-leaf result and the
                     eight-leaf result are described as indirect.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "scripts/run_kernel_debug_return_abi_qemutest.sh"
TAKIBI = ROOT / "_build/default/bin/main.exe"
FIXTURE = ROOT / "kernel/tests/debug_return_abi/fixture.tkb"

EXPECTED = {
    "direct-classifier":
        "return ABI mismatch at nine: the caller observed normal-corrupt",
    "c-size-rule":
        "return ABI mismatch at direct: the caller observed normal-corrupt",
}


def regress(metadata, mode):
    for variant in metadata["variants"]:
        abi = variant["return_abi"]
        if mode == "direct-classifier" and abi["kind"] == "indirect":
            leaves = [{"register": "x0", "offset": 0, "size": 4}]
            leaves += [{"register": f"x{i}", "offset": 8 * i, "size": 8}
                       for i in range(1, (variant["size"] // 8))]
            variant["return_abi"] = {"kind": "registers",
                                     "return_address_register": "x30",
                                     "parts": leaves}
        if mode == "c-size-rule" and variant["size"] > 16:
            variant["return_abi"] = {"kind": "indirect",
                                     "pointer_register": "x8",
                                     "return_address_register": "x30"}
    return metadata


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in EXPECTED:
        sys.exit("usage: run_kernel_debug_return_abi_counterfactual.py "
                 + "|".join(EXPECTED))
    mode = sys.argv[1]
    artifacts = Path(os.environ.get(
        "TAKIBI_LANE_ARTIFACT_ROOT", ROOT / "_build")) / \
        "kernel-debug-return-abi-qemu" / f"counterfactual-{mode}"
    artifacts.mkdir(parents=True, exist_ok=True)
    real = artifacts / "real-metadata.json"
    subprocess.run([str(TAKIBI), str(FIXTURE), "--target", "aarch64-none-elf",
                    "--cpu", "cortex-a53", "--frame-pointers", "--forbid-trap",
                    "--emit-debug-metadata", str(real)], check=True, timeout=60)
    wrong = artifacts / "regressed-metadata.json"
    wrong.write_text(json.dumps(regress(json.loads(real.read_text()), mode)),
                     encoding="ascii")
    env = dict(os.environ, DEBUG_RETURN_ABI_COUNTERFACTUAL="",
               DEBUG_RETURN_ABI_FLAVOR="production",
               DEBUG_RETURN_ABI_METADATA=str(wrong),
               DEBUG_RETURN_ABI_LABEL=f"counterfactual {mode}",
               DEBUG_RETURN_ABI_ARTIFACT_DIR=str(artifacts / "lane"))
    run = subprocess.run(["bash", str(RUNNER)], env=env, text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         timeout=120)
    (artifacts / "lane.log").write_text(run.stdout, encoding="utf-8")
    if run.returncode == 0:
        print(f"FAIL debug-return-abi counterfactual {mode}: the lane passed "
              f"with a regressed classifier; log: {artifacts / 'lane.log'}")
        return 1
    if EXPECTED[mode] not in run.stdout:
        print(f"FAIL debug-return-abi counterfactual {mode}: the lane failed "
              f"without '{EXPECTED[mode]}'; log: {artifacts / 'lane.log'}")
        return 1
    print(f"PASS debug-return-abi counterfactual {mode}: the lane refused it "
          f"with '{EXPECTED[mode]}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
