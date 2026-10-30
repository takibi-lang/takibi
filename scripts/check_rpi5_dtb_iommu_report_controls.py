#!/usr/bin/env python3
"""Controls for scripts/rpi5_dtb_iommu_report.py (GitHub issue #1032).

Builds small flattened device trees in memory and checks what the report
says about them: an IOMMU node resolved through `iommus`, a pcie2/rp1 tree
with no IOMMU property, and a blob that is not an FDT.

Exit code only (0 = pass, 1 = fail).
"""

import io
import struct
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rpi5_dtb_iommu_report as report_module  # noqa: E402
from pass_line import report_pass  # noqa: E402


def fdt(tree):
    """tree: (name, [(prop, bytes)], [children])."""
    strings, offsets, body = bytearray(), {}, bytearray()

    def name_offset(name):
        if name not in offsets:
            offsets[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return offsets[name]

    def pad():
        while len(body) % 4:
            body.append(0)

    def emit(node):
        name, props, children = node
        body.extend(struct.pack(">I", 1))
        body.extend(name.encode() + b"\0")
        pad()
        for prop, value in props:
            body.extend(struct.pack(">III", 3, len(value), name_offset(prop)))
            body.extend(value)
            pad()
        for child in children:
            emit(child)
        body.extend(struct.pack(">I", 2))

    emit(tree)
    body.extend(struct.pack(">I", 9))
    off_struct = 40 + 16
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)
    header = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_strings, 40,
                         17, 16, 0, len(strings), len(body))
    return header + bytes(16) + bytes(body) + bytes(strings)


def cell(*values):
    return b"".join(struct.pack(">I", v) for v in values)


JUDGED = []


def run(blob):
    JUDGED.append(blob)
    with tempfile.NamedTemporaryFile(suffix=".dtb") as handle:
        handle.write(blob)
        handle.flush()
        out = io.StringIO()
        status = report_module.report(handle.name, out)
        return status, out.getvalue()


def main():
    failures = []
    behind = fdt(("", [], [
        ("iommu@5100", [("compatible", b"brcm,bcm2712-iommu\0"), ("phandle", cell(7))], []),
        ("pcie@1000120000", [("dma-ranges", cell(0x2000000, 0, 0))], [
            ("rp1", [("iommus", cell(7))], [("ethernet@100000", [], [])]),
        ]),
    ]))
    status, text = run(behind)
    for needle in ("iommu-node: /iommu@5100 compatible=brcm,bcm2712-iommu phandle=7",
                   "property: /pcie@1000120000/rp1 iommus=<0x7> -> /iommu@5100",
                   "subtree: /pcie@1000120000/rp1/ethernet@100000 iommu-properties=none",
                   "verdict: 1 node(s) carry iommus/iommu-map; 1 IOMMU node(s)"):
        if status != 0 or needle not in text:
            failures.append(f"behind-an-IOMMU tree: missing {needle!r}\n{text}")
    bare = fdt(("", [], [("pcie@1000120000", [], [("rp1", [], [])])]))
    status, text = run(bare)
    for needle in ("iommu-node: none", "subtree: /pcie@1000120000/rp1 iommu-properties=none",
                   "verdict: 0 node(s) carry iommus/iommu-map; 0 IOMMU node(s)"):
        if status != 0 or needle not in text:
            failures.append(f"bare tree: missing {needle!r}\n{text}")
    try:
        run(b"\0" * 64)
        failures.append("a blob that is not an FDT was accepted")
    except ValueError:
        pass
    if failures:
        for failure in failures:
            print(f"ERROR rpi5-dtb-iommu-report-controls: {failure}")
        return 1
    report_pass("rpi5-dtb-iommu-report-controls",
                f"{len(JUDGED)} trees judged as specified", trees=len(JUDGED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
