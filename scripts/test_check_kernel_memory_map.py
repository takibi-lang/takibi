#!/usr/bin/env python3
"""Positive and faithful negative controls for allocator layout fixtures."""

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_kernel_memory_map.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_kernel_memory_map", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {CHECKER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_fixtures(checker, root, qemu_pages, rpi5_pages):
    prefix = "mem" + "ory"
    paths = [
        "kernel/tests/qemu/views/boot.expected",
        "kernel/tests/rpi5/views/boot.expected",
    ]
    for relative, pages in zip(paths, (qemu_pages, rpi5_pages), strict=True):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"{prefix}: test allocator_pages={pages}\n",
            encoding="ascii",
        )

    fdt = root / "kernel/tests/check_fdt_multibank_qemu.py"
    fdt.parent.mkdir(parents=True, exist_ok=True)
    fdt.write_text(
        "MULTIBANK_EXPECTED = "
        f'("{prefix}: test allocator_pages={qemu_pages}\\n")\n'
        "LOW_MEMORY_EXPECTED = "
        f'("{prefix}: test allocator_pages={checker.page_span(0x40200000, checker.QEMU_LOW_RAM_END, "test")}\\n")\n'
        "DISCONTIGUOUS_MEMORY_EXPECTED = "
        f'("{prefix}: test allocator_pages={checker.page_span(0x40200000, checker.QEMU_HOLE_FIRST_END, "test") + checker.page_span(checker.QEMU_HOLE_SECOND_START, checker.QEMU_RAM_END, "test")}\\n")\n',
        encoding="ascii",
    )


def run_main(checker):
    output = io.StringIO()
    saved_argv = sys.argv
    sys.argv = [str(CHECKER)]
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                checker.main()
                status = 0
            except SystemExit as error:
                status = int(error.code)
    finally:
        sys.argv = saved_argv
    return status, output.getvalue()


OFFSETS = [
    ("boot_stack_run_bottom", 0x00000), ("boot_stack_bottom", 0x04000),
    ("boot_stack_top", 0x08000), ("secondary_stack_run_bottom", 0x08000),
    ("secondary_stack_bottom", 0x0C000), ("secondary_stack_top", 0x10000),
    ("percpu_stack_base", 0x10000), ("percpu_stack_end", 0x30000),
    ("usable_ram_start", 0x30000),
]


def layout_doc(offsets=OFFSETS, ceiling=0x00400000):
    rows = "\n".join(
        f"| `{name}` | `+0x{offset:05x}` | linker script `.stack` "
        f"| CHECKED (ELF offset) |"
        for name, offset in offsets)
    return (
        "# fixture\n\n"
        "<!-- checked: elf-offsets -->\n\n"
        "| Symbol | Offset | Defined by | State |\n"
        "|---|---|---|---|\n"
        f"{rows}\n\n"
        "<!-- checked: elf-ceiling -->\n\n"
        "| Span | Ceiling | State |\n"
        "|---|---|---|\n"
        f"| `usable_ram_start` - `_start` | `0x{ceiling:08x}` "
        f"| CHECKED (ELF ceiling) |\n")


def layout_symbols(start=0x00200000, anchor=0x00560000, bss_end=None,
                   qemu_skew=0):
    """A plausible linked layout, per platform, with knobs for the negatives."""
    def one(base_start, base_anchor, skew):
        symbols = {"_start": base_start,
                   "__bss_start": base_anchor - 0x2000,
                   "__bss_end": base_anchor - 0x100 if bss_end is None else bss_end}
        for index, (name, offset) in enumerate(OFFSETS):
            symbols[name] = base_anchor + offset + (skew if index else 0)
        return symbols
    return {"rpi5.elf": one(start, anchor, 0),
            "qemu.elf": one(0x40000000, 0x40368000, qemu_skew)}


def layout_controls(checker):
    """Every way the document's own tables are allowed to fail, exercised.

    These checks are built not to fire on ordinary work -- that is the whole
    point of recording offsets and a ceiling instead of twenty addresses --
    which is exactly why they need controls. A check nothing can make fail
    is indistinguishable from one that is not running.
    """
    checker.DOC = Path("MEMORY_MAP.md")
    checker.ELFS = {"RPi5": Path("rpi5.elf"), "QEMU": Path("qemu.elf")}

    def run(call):
        problems = []
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output), \
                    contextlib.redirect_stderr(output):
                call(problems)
            return problems, output.getvalue(), False
        except SystemExit:
            return problems, output.getvalue(), True

    def use(symbols):
        checker.nm_symbols = lambda elf: symbols[elf.name]

    cases = []

    use(layout_symbols())
    cases.append(("current fixtures pass", lambda p: (
        checker.check_elf_offsets(layout_doc(), p),
        checker.check_image_ceiling(layout_doc(), p),
        checker.check_layout_invariants(p)), False, ""))

    bad = [(n, o + 0x1000 if n == "percpu_stack_base" else o)
           for n, o in OFFSETS]
    cases.append(("a wrong offset is caught",
                  lambda p: checker.check_elf_offsets(layout_doc(bad), p),
                  True, "percpu_stack_base"))

    cases.append(("the ceiling is enforced",
                  lambda p: checker.check_image_ceiling(
                      layout_doc(ceiling=0x00100000), p),
                  True, "reached the recorded ceiling"))

    cases.append(("a conflict marker is refused", lambda p: (
        checker.reject_conflict_markers(
            layout_doc().replace("| `boot_stack_top`",
                                 "<<<<<<< HEAD\n| `boot_stack_top`", 1)), p),
        None, "merge conflict marker"))

    cases.append(("rows outside the table are refused", lambda p: (
        checker.check_elf_offsets(
            layout_doc().replace("| `percpu_stack_base`",
                                 "stray prose\n| `percpu_stack_base`", 1), p)),
        None, "outside it"))

    cases.append(("an anchor that is not first is refused", lambda p: (
        checker.check_elf_offsets(layout_doc(OFFSETS[1:] + OFFSETS[:1]), p)),
        None, "must open with"))

    results = []
    for label, call, expect_problems, needle in cases:
        problems, output, exited = run(call)
        text = output + "\n".join(problems)
        if expect_problems is None:
            ok = exited and needle in text
        elif expect_problems:
            ok = bool(problems) and needle in text
        else:
            ok = not problems and not exited
        results.append((ok, label, text))

    # Platform divergence: a single shared column cannot state two shapes.
    use(layout_symbols(qemu_skew=0x1000))
    problems, output, exited = run(
        lambda p: checker.check_elf_offsets(layout_doc(), p))
    results.append((bool(problems)
                    and "different offset on each platform"
                    in "\n".join(problems),
                    "platform divergence is caught", "\n".join(problems)))

    # An out-of-order or misaligned boundary, which is what replaced the
    # absolute rows for __bss_start, __bss_end and the stack block's base.
    use(layout_symbols(bss_end=0x00570000))
    problems, _, _ = run(checker.check_layout_invariants)
    results.append((any("out of order" in one for one in problems),
                    "an out-of-order boundary is caught", "\n".join(problems)))

    use(layout_symbols(anchor=0x00560100))
    problems, _, _ = run(checker.check_layout_invariants)
    results.append((any("not 0x8000-aligned" in one for one in problems),
                    "a misaligned stack block is caught", "\n".join(problems)))

    for ok, label, text in results:
        if not ok:
            print(f"FAIL kernel-memory-map control: {label}")
            print(text)
            return 1
    print(f"PASS kernel-memory-map layout controls: {len(results)} cases "
          f"(offsets, ceiling, conflict markers, truncation, anchor, "
          f"divergence, ordering, alignment)")
    return 0


def main():
    checker = load_checker()
    qemu_start = 0x40200000
    rpi5_start = 0x00400000
    qemu_pages = checker.page_span(qemu_start, checker.QEMU_RAM_END, "test")
    rpi5_pages = checker.page_span(
        rpi5_start, checker.RPI5_MANAGED_RAM_END, "test"
    )

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        checker.REPO = root
        checker.DOC = root / "kernel/MEMORY_MAP.md"
        checker.DOC.parent.mkdir(parents=True)
        checker.DOC.write_text("test\n", encoding="ascii")
        checker.ELFS = {"RPi5": Path("rpi5.elf"), "QEMU": Path("qemu.elf")}
        checker.nm_symbols = lambda elf: {
            "usable_ram_start": rpi5_start if elf.name == "rpi5.elf" else qemu_start
        }
        checker.check_elf_symbols = lambda _text, _problems: None
        checker.check_consts = lambda _text, _problems: None
        # This control is about the allocator fixtures; the document's own
        # tables get their own controls in layout_controls() below.
        checker.check_elf_offsets = lambda _text, _problems: None
        checker.check_image_ceiling = lambda _text, _problems: None
        checker.check_layout_invariants = lambda _problems: None

        write_fixtures(checker, root, qemu_pages, rpi5_pages)
        positive_status, positive_output = run_main(checker)
        if positive_status != 0:
            print("FAIL kernel-memory-map control: current fixtures failed")
            print(positive_output, end="")
            return 1

        write_fixtures(checker, root, qemu_pages - 1, rpi5_pages)
        negative_status, negative_output = run_main(checker)
        expected = (
            "`kernel/tests/qemu/views/boot.expected` says "
            f"allocator_pages={qemu_pages - 1}, linked layout requires {qemu_pages}"
        )
        if negative_status == 0:
            print("FAIL kernel-memory-map control: stale fixture succeeded")
            return 1
        if expected not in negative_output:
            print("FAIL kernel-memory-map control: wrong diagnostic")
            print(negative_output, end="")
            return 1

    print("PASS kernel-memory-map controls: positive and one-page-stale fixtures")
    # A fresh module: the allocator control above stubs out the very
    # functions these controls exist to exercise.
    return layout_controls(load_checker())


if __name__ == "__main__":
    sys.exit(main())
