#!/usr/bin/env python3
"""Controls for the MMU-off vector-store backstop (GitHub issues #746, #762).

scripts/buildcheck_kernel_asm_invariants.py checks every function an
`!{mmu_off}` root reaches, read from the compiler's call graph, for a
q-register store that could be unaligned on Device memory. These controls
feed it a synthetic call graph and synthetic instructions: a misaligned
store in a reached callee (not on the #746 hand list) is reported, an
aligned one passes, the same store in an unreached function is not
examined, and a graph that drops a #746 function is refused.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import buildcheck_kernel_asm_invariants as asm  # noqa: E402
from pass_line import report_pass  # noqa: E402

HEADER = ("file\tline\tend_line\tname\tqualifiers\tdeclared\teffects\tparams"
          "\tcallees\tcallers\tvalues\tbody_hash\n")


def graph(rows):
    handle = tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False)
    handle.write("# takibi call graph, format 1\n" + HEADER)
    for name, declared, callees in rows:
        handle.write(f"f.tkb\t1\t2\t{name}\t-\t{declared}\t-\t-\t{callees}\t-\t-\t-\n")
    handle.close()
    return handle.name


def main():
    allocator = [(name, "-", "-") for name in asm.MMU_OFF_ALLOCATOR_FUNCTIONS]
    path = graph(allocator + [
        ("boot_root", "mmu_off",
         "boot_helper@f.tkb:3," + ",".join(
             f"{n}@f.tkb:1" for n in asm.MMU_OFF_ALLOCATOR_FUNCTIONS)),
        ("boot_helper", "-", "-"),
        ("later", "-", "-"),
    ])
    failures = []
    claims = 0
    try:
        roots, reached = asm.mmu_off_reachable(path)
        if roots != ["boot_root"] or "boot_helper" not in reached or "later" in reached:
            failures.append(f"reachability: roots {roots}, reached {sorted(reached)}")
        present = [(0x10, "ret", "page_allocator_init_with"),
                   (0x14, "ret", "page_alloc_boot")]
        bad = present + [(0x20, "str q0, [x19, #8]", "boot_helper")]
        good = present + [(0x20, "str q0, [x19, #16]", "boot_helper")]
        elsewhere = present + [(0x20, "str q0, [x19, #8]", "later")]
        claims += 1
        if not asm.check_mmu_off_vector_stores(bad, reached):
            failures.append("a misaligned q store in a reached callee was not reported")
        claims += 1
        if asm.check_mmu_off_vector_stores(good, reached):
            failures.append("an aligned q store was reported")
        claims += 1
        if asm.check_mmu_off_vector_stores(elsewhere, reached):
            failures.append("a function the roots do not reach was examined")
        short = reached - {"page_free_locked"}
        claims += 1
        if not any("#762" in f for f in asm.check_mmu_off_vector_stores(good, short)):
            failures.append("a graph without a #746 function was not refused")
    finally:
        os.unlink(path)
    if failures:
        for failure in failures:
            print(f"FAIL mmu-off-vector-store controls: {failure}")
        return 1
    report_pass("mmu-off-vector-store controls",
                "the backstop follows the call graph from !{mmu_off} roots: a "
                "misaligned q store in a reached callee is reported, an aligned "
                "one and an unreached function are not, and a graph missing a "
                "#746 function is refused", claims=claims)
    return 0


if __name__ == "__main__":
    sys.exit(main())
