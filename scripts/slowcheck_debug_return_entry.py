#!/usr/bin/env python3
"""Exercise indirect forced returns at and after machine entry in real GDB.

The native fixture checks the debugger's entry guard and memory write, not
AArch64 ABI classification; the kernel allocation rollback lane and
kernelcheck-debug-return-abi-qemu (GitHub issue #713) cover that. The guard
runs twice: with DWARF, and stripped of it, where it falls back to the ELF
symbol table as it must for a production build.
"""

import json
import subprocess
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
DIAGNOSTIC = "indirect forced return requires the innermost frame at its first instruction"


def run(args):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=20)


def main():
    cases = CaseCount()
    with tempfile.TemporaryDirectory(prefix="takibi-debug-return-") as directory:
        work = Path(directory)
        source = work / "fixture.c"
        binary = work / "fixture"
        metadata = work / "metadata.json"
        source.write_text('''/* A real inferior for debugger entry and result-buffer controls. */
__attribute__((noinline)) void probe(unsigned char *result) { result[0] = 99; }
int main(void) { unsigned char result[8] = {0}; probe(result); return result[0] != 7; }
''', encoding="ascii")
        for debug_flags in (["-g"], ["-g0"]):
            built = run(["cc", *debug_flags, "-O0", "-fno-pie", "-no-pie",
                         str(source), "-o", str(binary)])
            assert built.returncode == 0, built.stdout
            metadata.write_text(json.dumps({"format": 2, "enums": [], "constants": [],
                "variants": [{"name": "Result", "size": 8, "tag_size": 8,
                    "tag_offset": 0, "cases": [{"name": "Failed", "tag": 7, "payload": None}],
                    "return_abi": {"kind": "indirect", "pointer_register": "rdi"}}]}),
                encoding="ascii")
            setup = (f"set confirm off\nset debuginfod enabled off\nsource {ROOT / 'scripts/kernel_debug_metadata.gdb'}\n"
                     f"takibi-debug-metadata {metadata}\nbreak *probe\nrun\n")
            negative = work / "negative.gdb"
            negative.write_text(setup + "set $pc = $pc + 1\n"
                                "takibi-force-variant-return Result Failed\n", encoding="ascii")
            rejected = run(["gdb-multiarch", "-q", "-nx", "-batch", "-x", str(negative), str(binary)])
            assert rejected.returncode != 0, rejected.stdout
            assert DIAGNOSTIC in rejected.stdout, rejected.stdout
            cases.note()
            positive = work / "positive.gdb"
            positive.write_text(setup + '''python
exit_codes = []
gdb.events.exited.connect(lambda event: exit_codes.append(event.exit_code))
end
takibi-force-variant-return Result Failed
continue
python
assert exit_codes == [0], exit_codes
end
''', encoding="ascii")
            accepted = run(["gdb-multiarch", "-q", "-nx", "-batch", "-x", str(positive), str(binary)])
            assert accepted.returncode == 0, accepted.stdout
            assert "Result::Failed via indirect" in accepted.stdout, accepted.stdout
            cases.note()
    report_pass("debug-return-entry", "real GDB accepts entry and rejects a late PC, with and without DWARF",
                cases=cases.ran)


if __name__ == "__main__":
    main()
