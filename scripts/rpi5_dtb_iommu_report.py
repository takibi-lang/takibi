#!/usr/bin/env python3
"""Which RPi5 devices sit behind an IOMMU, read from the firmware's own DTB.

GitHub issue #1032 (IOMMU route B, fact-finding): before an IOMMU slice is
designed for RP1 (GEM, xHCI), the board must say whether pcie2 -- the RP1
link -- is behind any BCM2712 IOMMU at all. The firmware passes its DTB to
the kernel in x0, and entry.S keeps that address in `boot_dtb_address`.

    capture ELF OUT.dtb   halt a core in EL1 over SWD, read boot_dtb_address,
                          the blob's header and then the whole blob, resume.
                          Needs the RPi5 lease (it drives the debug probe).
    report DTB            print, with no board: every IOMMU node (by
                          compatible) with its phandle, every node carrying
                          iommus / iommu-map / iommu-map-mask / dma-ranges,
                          and the pcie2 and rp1 subtrees with those
                          properties resolved against the IOMMU phandles.

No product code; the kernel image is not modified. Exit status: 0 when the
report or capture completed, 1 otherwise.
"""

import argparse
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BCM2712_CFG = REPO_ROOT / "kernel" / "platform" / "rpi5" / "jtag" / "bcm2712.cfg"
OPENOCD_TIMEOUT = 60.0
DTB_SYMBOL = "boot_dtb_address"
FDT_MAGIC = 0xD00DFEED
MAX_DTB_BYTES = 1 << 20

# The RP1 link and the RP1 node, as BCM2712's firmware DTB names them.
SUBTREES = ("pcie@1000120000", "rp1")
IOMMU_PROPERTIES = ("iommus", "iommu-map", "iommu-map-mask", "dma-ranges")

TCL = r"""
init
set reader -1
for {set c 0} {$c < 4} {incr c} {
    targets bcm2712.cpu$c
    if {[catch {halt 1000} error]} { echo "dtb: cpu=$c halt-error=$error" ; continue }
    if {[catch {set cpsr [reg cpsr]} error]} { continue }
    if {$reader < 0 && [scan [lindex $cpsr end] %%x value] == 1 && (($value >> 2) & 3) >= 1} {
        set reader $c
    }
}
if {$reader < 0} {
    echo "dtb: error=no core halted in EL1"
} else {
    targets bcm2712.cpu$reader
    set words [read_memory %(symbol)s 32 2]
    set base [expr {[lindex $words 0] | ([lindex $words 1] << 32)}]
    echo "dtb: base=[format 0x%%x $base]"
    set header [read_memory $base 32 2]
    echo "dtb: header=$header"
    set magic [lindex $header 0]
    set size [lindex $header 1]
    echo "dtb: size-be=[format 0x%%08x $size] magic-be=[format 0x%%08x $magic]"
    set swapped [expr {(($size & 0xff) << 24) | (($size & 0xff00) << 8) | (($size >> 8) & 0xff00) | (($size >> 24) & 0xff)}]
    if {$swapped > 0 && $swapped <= %(limit)d} {
        dump_image %(out)s $base $swapped
        echo "dtb: dumped=$swapped"
    } else {
        echo "dtb: error=implausible size $swapped"
    }
}
for {set c 0} {$c < 4} {incr c} {
    targets bcm2712.cpu$c
    catch {resume}
}
shutdown
"""


def symbol_address(elf, name):
    listing = subprocess.run(["llvm-nm-19", str(elf)], check=True,
                             capture_output=True, text=True, timeout=10).stdout
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] == name:
            return int(fields[0], 16)
    return None


def capture(elf, out, runner=subprocess.run):
    address = symbol_address(elf, DTB_SYMBOL)
    if address is None:
        print(f"dtb: error={DTB_SYMBOL} not in {elf}")
        return 1
    with tempfile.NamedTemporaryFile("w", suffix=".tcl", encoding="ascii") as script:
        script.write(TCL % {"symbol": f"{address:#x}", "out": str(Path(out).resolve()),
                            "limit": MAX_DTB_BYTES})
        script.flush()
        result = runner(["openocd", "-f", "interface/cmsis-dap.cfg", "-f",
                         str(BCM2712_CFG), "-f", script.name],
                        capture_output=True, text=True, errors="replace",
                        timeout=OPENOCD_TIMEOUT)
    text = (result.stdout or "") + (result.stderr or "")
    for line in text.splitlines():
        if line.startswith("dtb: "):
            print(line)
    return 0 if "dtb: dumped=" in text and Path(out).exists() else 1


def parse_fdt(blob):
    """(path, {property: bytes}) for every node, in tree order."""
    magic, total, off_struct, off_strings = struct.unpack(">IIII", blob[:16])
    if magic != FDT_MAGIC:
        raise ValueError(f"not an FDT (magic {magic:#x})")
    if total > len(blob):
        raise ValueError(f"truncated FDT: header says {total} bytes, have {len(blob)}")
    strings = blob[off_strings:]
    nodes, stack, pos = [], [], off_struct
    while True:
        (token,) = struct.unpack(">I", blob[pos:pos + 4])
        pos += 4
        if token == 1:
            end = blob.index(b"\0", pos)
            name = blob[pos:end].decode("ascii", "replace")
            pos = (end + 4) & ~3
            path = "/" if not stack else (stack[-1][0].rstrip("/") + "/" + name)
            node = (path, {})
            nodes.append(node)
            stack.append(node)
        elif token == 2:
            stack.pop()
        elif token == 3:
            length, nameoff = struct.unpack(">II", blob[pos:pos + 8])
            pos += 8
            value = blob[pos:pos + length]
            pos = (pos + length + 3) & ~3
            pname = strings[nameoff:strings.index(b"\0", nameoff)].decode("ascii")
            stack[-1][1][pname] = value
        elif token == 4:
            continue
        elif token == 9:
            return nodes
        else:
            raise ValueError(f"bad FDT token {token} at {pos - 4}")


def cells(value):
    return [struct.unpack(">I", value[i:i + 4])[0] for i in range(0, len(value) - 3, 4)]


def text_list(value):
    return [part.decode("ascii", "replace") for part in value.split(b"\0") if part]


def report(dtb, out=sys.stdout):
    nodes = parse_fdt(Path(dtb).read_bytes())
    iommus = {}
    for path, props in nodes:
        compatible = text_list(props.get("compatible", b""))
        if any("iommu" in c or "smmu" in c for c in compatible):
            handle = cells(props["phandle"])[0] if "phandle" in props else None
            iommus[handle] = path
            print(f"iommu-node: {path} compatible={','.join(compatible)} "
                  f"phandle={handle if handle is not None else '-'}", file=out)
    if not iommus:
        print("iommu-node: none", file=out)
    carriers = 0
    for path, props in nodes:
        for name in IOMMU_PROPERTIES:
            if name not in props:
                continue
            words = cells(props[name])
            note = ""
            if name == "iommus" and words:
                note = " -> " + iommus.get(words[0], f"phandle {words[0]} (not an IOMMU node)")
            print(f"property: {path} {name}=<{' '.join(f'{w:#x}' for w in words)}>{note}",
                  file=out)
            if name != "dma-ranges":
                carriers += 1
    for root in SUBTREES:
        matched = [(p, q) for p, q in nodes if any(part.startswith(root) for part in p.split("/"))]
        if not matched:
            print(f"subtree: {root} absent", file=out)
            continue
        for path, props in matched:
            held = [n for n in IOMMU_PROPERTIES if n in props]
            print(f"subtree: {path} iommu-properties={','.join(held) if held else 'none'}",
                  file=out)
    print(f"verdict: {carriers} node(s) carry iommus/iommu-map; "
          f"{len([k for k in iommus])} IOMMU node(s)", file=out)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    cap = sub.add_parser("capture")
    cap.add_argument("elf")
    cap.add_argument("out")
    rep = sub.add_parser("report")
    rep.add_argument("dtb")
    args = parser.parse_args(argv)
    try:
        if args.command == "capture":
            return capture(args.elf, args.out)
        return report(args.dtb)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"dtb: error={error}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
