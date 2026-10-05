#!/usr/bin/env python3
"""Compile real kernel overlays to enforce backing-record write authority.

Run after kernelbuild with the built compiler and the QEMU root source list.
Layout emission performs type checking without generating another kernel.
Unlike a copied API fixture, these controls exercise the maintained signatures.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import tempfile

from pass_line import CaseCount, report_pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path)
    parser.add_argument("sources", nargs="+")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    compiler = args.compiler.resolve()
    backing = Path("kernel/mm/address_space.tkb")
    source = (repo / backing).read_text(encoding="ascii")
    cases = [
        ("maintained kernel", backing, "", None),
        ("borrowed evidence", backing, """
private fn backing_exists_control(
        evidence: borrow AddressSpaceBackingExists[slot],
        value: AddressSpaceBacking) !{unsafe} {
    address_space_backing_write(evidence, value);
    address_space_backing_write(evidence, value);
}
""", None),
        ("write without evidence", backing, """
private fn backing_exists_control(root: AddressSpaceRoot,
        value: AddressSpaceBacking) !{unsafe} {
    address_space_backing_write(root, value);
}
""", ("cannot unify", "AddressSpaceBackingExists", "AddressSpaceRoot")),
        ("allocate without evidence", backing, """
private fn backing_exists_control(root: AddressSpaceRoot)
        -> AddressSpaceAllocateResult {
    return address_space_allocate_root(root);
}
""", ("cannot unify", "AddressSpaceBackingExists", "AddressSpaceRoot")),
        ("foreign evidence constructor", Path(args.sources[-1]), """
private fn backing_exists_control(root: AddressSpaceRoot,
        value: AddressSpaceBacking) -> AddressSpaceBackingReady {
    let mut evidence: AddressSpaceBackingExists[0] = { 0, root, value };
    return AddressSpaceBackingReady::Ready(evidence);
}
""", ("private", "AddressSpaceBackingExists")),
    ]
    image = Path("kernel/mm/process_image.tkb")
    cases.extend([
        ("image borrowed evidence", image, """
private fn image_exists_control() {
    let evidence = match process_image_record_ensure(0) {
        ProcessImageRecordReady::Missing => { return; }
        ProcessImageRecordReady::Ready(ready) => { ready }
    };
    process_image_set_active_page_count(0, evidence, 0);
    process_image_set_stack_growth_active(0, evidence, false);
}
""", None),
        ("image wrong root", image, """
private fn image_exists_control() {
    let evidence = match process_image_record_ensure(0) {
        ProcessImageRecordReady::Missing => { return; }
        ProcessImageRecordReady::Ready(ready) => { ready }
    };
    process_image_set_active_page_count(1, evidence, 0);
}
""", ("static value mismatch",)),
        ("foreign image view mint", Path(args.sources[-1]), """
private fn image_exists_control() -> ProcessImageRecordExists[0] {
    return view ProcessImageRecordExists[0];
}
""", ("private", "ProcessImageRecordExists")),
    ])
    for field, value in [
            ("active_page_count", "0"), ("stack_lowest_l3", "0"),
            ("stack_growth_active", "false"), ("stack_top_page", "0"),
            ("stack_low_page", "0"), ("heap_page_count", "0"),
            ("exec_image_installed", "false"), ("exec_image_page_count", "0"),
            ("clone_vm_outstanding", "false"), ("clone_vm_source_root", "0"),
            ("clone_vm_page_count", "0")]:
        cases.append((f"image {field} without evidence", image,
                      f"\nprivate fn image_exists_control() {{ process_image_set_{field}(0, {value}); }}\n",
                      (f"process_image_set_{field} expects 3 argument(s), got 2",)))
    ran = CaseCount()
    with tempfile.TemporaryDirectory(prefix="takibi-backing-exists-") as tmp:
        overlay = Path(tmp)
        # Symlink files individually so changing one source cannot touch the
        # real tree. Generated kernel files remain available after kernelbuild.
        for original in (repo / "kernel").rglob("*"):
            relative = original.relative_to(repo)
            target = overlay / relative
            if original.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif original.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(original)
        for name, edited, addition, expected in cases:
            target = overlay / edited
            original = source if edited == backing else (repo / edited).read_text(encoding="ascii")
            target.unlink()
            target.write_text(original + addition, encoding="ascii")
            result = subprocess.run(
                [str(compiler), *args.sources, "--regions", "--forbid-trap",
                 "--target", "aarch64-none-elf", "--cpu", "cortex-a53",
                 "--emit-struct-layout", "AddressSpaceBacking", "-o", str(overlay / "layout")],
                cwd=overlay, capture_output=True, text=True, check=False)
            ran.note()
            output = result.stdout + result.stderr
            status_ok = result.returncode == 0 if expected is None else result.returncode != 0
            diagnostic_ok = expected is None or all(part in output for part in expected)
            if not status_ok or not diagnostic_ok:
                print(f"FAIL backing-exists: {name}: status={result.returncode}; expected={expected}\n{output}")
                return 1
            target.unlink()
            target.symlink_to(repo / edited)
    report_pass("backing-exists", "real kernel accepts borrowed evidence and rejects unensured writes, wrong-root image evidence and foreign minting", cases=ran.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
