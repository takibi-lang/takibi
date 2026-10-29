#!/usr/bin/env python3
"""The frame API rule (GitHub issue #1018): a public function of a mint
file returns a capability type, never a raw pointer or a bare address.

The mint files of `kernel/RAW_MINT_FILES` are Takibi's frame (#1017): the
only files allowed raw access. A public function there that hands out a
raw pointer moves the hand-checked reasoning to every caller, and the
boundary stops meaning anything. This check refuses, in a listed mint file,
a non-private function whose return type

  * contains a raw pointer (`*T`, `*io T`, `*align(N) T`, `*const T`), or
  * names `usize` (bare, refined, or in a tuple) while the function's name
    says it is an address (ADDRESS_NAME below) -- an address by convention,

unless the function is in RATCHET with the issue that retires it. The
ratchet only shrinks: an entry whose function is gone, private, or typed
now is stale and fails (#796's rule), and so does an entry for a file
that left the mint list.

Signatures come from a scan of the source, not from the compiler's
--facts callgraph.tsv table (#987): that table carries `params` but no return
type, and it is written only by a kernel build while this check runs in
langcheck. When the table gains a return-type column the scan here is
replaced by a read of it (docs/CALL_GRAPH.md, "Changing the format").

Not covered (a scan cannot type them): public struct fields and variant
payloads reachable from a result, a result type alias that hides a
pointer, and a `usize` address whose name does not say so.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only, per_file

ROOT = Path(__file__).resolve().parent.parent
MINT_LIST = ROOT / "kernel" / "RAW_MINT_FILES"

# (file, function) -> (issue that retires it, why it exports an address and
# the capability it moves to). Measured 2026-10-25, not guessed: ten raw
# returns, of which fdt_blob_base retired in the same commit (its only
# caller, linux_user/fdt, passes the fixture's own address now). None of
# the sixteen files has a public `*T` return.
EXPORT = "#1017"  # the frame's named API: a typed export instead of usize
RATCHET = {
    # The trap frame's address, read by the exception-entry assembly ABI
    # (gicv2 returns it to the vector) and by the stack-guard and DDB
    # reporters; FrameRef already carries it.
    ("kernel/arch/arm64/kernel/frame_ref.tkb", "frame_ref_address"):
        (EXPORT, "assembly ABI and reporter export of the trap frame"),
    ("kernel/arch/arm64/kernel/frame_ref.tkb", "frame_any_address"):
        (EXPORT, "assembly ABI export: the frame sp the vector restores"),
    # Device bus addresses: written to a descriptor, never dereferenced.
    # One mint for every device-visible address (#1162).
    ("kernel/drivers/dma_address.tkb", "virtio_span_address"):
        (EXPORT, "bus-address export of a DMA span to the device"),
    ("kernel/drivers/dma_address.tkb", "rp1_span_bus_address"):
        (EXPORT, "bus-address export of a DMA span to the device"),
    ("kernel/drivers/dma_address.tkb", "dma_span_cpu_address"):
        (EXPORT, "CPU physical address of a DMA span, for a DDB cache read"),
    # Physical addresses that callers turn back into access: these move to
    # owners.
    ("kernel/arch/arm64/mm/mmu.tkb", "mmu_user_l3_physical"):
        ("#637", "an L3 table's physical address; moves to a page-table owner"),
    ("kernel/boot/fdt.tkb", "fdt_memory_first_base"):
        ("#637", "a RAM bank base; moves to a memory-map region"),
}

ADDRESS_NAME = re.compile(
    r"address|physical|phys|_base\b|_base_|_ptr\b|pointer|_pa\b|_sp\b")
RAW_POINTER = re.compile(r"(?:^|[\s(,\[<])\*")
USIZE = re.compile(r"\busize\b")
FN_START = re.compile(
    r"^[ \t]*(private\s+)?(?:(?:inline|noinline)\s+)?fn\s+(\w+)", re.M)


def mint_files(text):
    return [line.strip() for line in text.splitlines()
            if line.strip() and not line.strip().startswith("#")]


def _balanced(text, index):
    """Index just past the bracket group opening at text[index]."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    for position in range(index, len(text)):
        char = text[position]
        if char in pairs:
            stack.append(pairs[char])
        elif stack and char == stack[-1]:
            stack.pop()
            if not stack:
                return position + 1
    return len(text)


def return_type(code, after_name):
    """The return type text of the signature whose name ends at
    `after_name`, or '' when it returns nothing."""
    index = code.find("(", after_name)
    if index < 0:
        return ""
    index = _balanced(code, index)
    rest = code[index:]
    stripped = rest.lstrip()
    if not stripped.startswith("->"):
        return ""
    start = index + len(rest) - len(stripped) + 2
    position = start
    while position < len(code) and code[position] in " \t\n":
        position += 1
    if position < len(code) and code[position] == "{":
        return code[start:_balanced(code, position)].strip()
    depth = 0
    end = position
    while end < len(code):
        char = code[end]
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif depth == 0 and (char in "{;" or code.startswith("!{", end)):
            break
        end += 1
    return " ".join(code[start:end].split())


@per_file
def raw_returns(text):
    """(function, return type, why) for each public raw return in `text`."""
    code = code_only(text)
    found = []
    for match in FN_START.finditer(code):
        if match.group(1):
            continue
        name = match.group(2)
        returned = return_type(code, match.end())
        if RAW_POINTER.search(returned):
            found.append((name, returned, "a raw pointer"))
        elif USIZE.search(returned) and ADDRESS_NAME.search(name):
            found.append((name, returned, "a usize address"))
    return tuple(found)


def problems(sources, mint_text, ratchet=None):
    """(failures, files checked) for `sources` ({relative path: text})."""
    ratchet = RATCHET if ratchet is None else ratchet
    files = mint_files(mint_text)
    failures = []
    seen = set()
    for path in files:
        if path not in sources:
            failures.append(f"{path}: listed in RAW_MINT_FILES but missing")
            continue
        for name, returned, why in raw_returns(sources[path]):
            seen.add((path, name))
            if (path, name) not in ratchet:
                failures.append(
                    f"{path}: public fn {name} returns {why} `{returned}`; "
                    f"return a capability type (a region, IoHandle, FrameRef, "
                    f"indexed owner, Place, slice), make it private, or list "
                    f"it in RATCHET with the issue that retires it")
    for key in ratchet:
        if key not in seen:
            failures.append(f"{key[0]}: RATCHET entry {key[1]} is stale "
                            f"(gone, private, typed now, or the file left "
                            f"the mint list); remove it")
    return failures, len(files)


def load():
    mint_text = MINT_LIST.read_text(encoding="utf-8")
    sources = {}
    for path in mint_files(mint_text):
        full = ROOT / path
        if full.exists():
            sources[path] = full.read_text(encoding="utf-8")
    return sources, mint_text


def main():
    sources, mint_text = load()
    failures, files = problems(sources, mint_text)
    for failure in failures:
        print(f"FAIL frame-api: {failure}", file=sys.stderr)
    if failures:
        return 1
    report_pass("frame-api",
                f"{files} mint files: no public raw return beyond "
                f"{len(RATCHET)} ratchet entries",
                files=files)
    return 0


if __name__ == "__main__":
    sys.exit(main())
