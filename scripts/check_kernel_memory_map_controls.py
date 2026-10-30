#!/usr/bin/env python3
"""Positive and faithful negative controls for allocator layout fixtures."""

from control_patch import replace_once
import contextlib
import importlib.util
import io
import sys
import subprocess
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "buildcheck_kernel_memory_map.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_kernel_memory_map", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {CHECKER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_fixtures(root, rpi5_pages="<allocator_pages>"):
    prefix = "mem" + "ory"
    for relative, pages in (("qemu", "<allocator_pages>"), ("rpi5", rpi5_pages)):
        path = root / "kernel/tests" / relative / "views/boot.expected"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"{prefix}: test allocator_pages={pages}\n",
            encoding="ascii",
        )


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def run_main(checker, *arguments):
    CASES.note()
    output = io.StringIO()
    saved_argv = sys.argv
    sys.argv = [str(CHECKER), *arguments]
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

    # The ceiling is the one row a person raises by hand, so its message has
    # to carry what raising it costs. Without the number the cheap reading is
    # "ordinary growth, raise it", and the SWD transfer that growth buys is
    # invisible from where the decision is made.
    cases.append(("the ceiling says what raising it costs",
                  lambda p: checker.check_image_ceiling(
                      layout_doc(ceiling=0x00100000), p),
                  True, "5.5 s on every RPi5 lane run"))
    cases.append(("the ceiling names the cheaper alternative",
                  lambda p: checker.check_image_ceiling(
                      layout_doc(ceiling=0x00100000), p),
                  True, "stop embedding it"))

    cases.append(("a conflict marker is refused", lambda p: (
        checker.reject_conflict_markers(
            replace_once(layout_doc(), "| `boot_stack_top`", "<<<<<<< HEAD\n| `boot_stack_top`")), p),
        None, "merge conflict marker"))

    cases.append(("rows outside the table are refused", lambda p: (
        checker.check_elf_offsets(
            replace_once(layout_doc(), "| `percpu_stack_base`", "stray prose\n| `percpu_stack_base`"), p)),
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
    report_pass(
        "kernel-memory-map layout controls",
        "offsets, ceiling, conflict markers, truncation, anchor, "
        "divergence, ordering and alignment are each exercised",
        cases=len(results))
    return 0


def qemu_boot_controls():
    """Link growing images and compare UART through the real shared view loop."""
    cases = 0
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        template = (ROOT / "kernel/tests/qemu/views/boot.expected").read_text()
        overlay = root / "overlay"
        platform = root / "platform"
        common = root / "common"
        artifacts = root / "artifacts"
        for path in (overlay, platform, common, artifacts):
            path.mkdir()
        (platform / "boot.filter").write_bytes(
            (ROOT / "kernel/tests/qemu/views/boot.filter").read_bytes())
        (platform / "boot.expected").write_text(template)
        script = root / "layout.ld"
        script.write_text("SECTIONS { . = 0x40200000; .bss : { *(.bss) } "
                          "usable_ram_start = ALIGN(0x8000); }\n")
        captures = []
        for size, pages in ((0x8000, 261624), (0x9000, 261616), (0x7000, 261624)):
            asm = root / "image.s"
            obj = root / "image.o"
            elf = root / f"image-{size}.elf"
            asm.write_text(f".bss\n.skip {size}\n")
            for command in (
                ["llvm-mc-19", "-triple=aarch64", "-filetype=obj", str(asm),
                 "-o", str(obj)],
                ["ld.lld-19", "-T", str(script), str(obj), "-o", str(elf)],
            ):
                subprocess.run(command, check=True, capture_output=True)
            result = subprocess.run(
                [sys.executable, str(CHECKER), "--qemu-boot-expected", str(elf)],
                capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            expected = template.replace("<allocator_pages>", str(pages))
            assert result.stdout == expected, result.stdout
            assert (platform / "boot.expected").read_text() == template
            cases += 1
            captures.append(result.stdout)

        command = ["bash", "-c", 'source "$1"; kernel_views_compare control '
                   '"$2" "$3" "$4" "$5" "$6"', "control",
                   str(ROOT / "scripts/kernel_views.sh"), str(artifacts),
                   str(root / "uart.log"), str(common), str(platform),
                   str(overlay)]
        for name, expected, observed, success in (
            ("release", captures[0], captures[0], True),
            ("debug growth", captures[1], captures[1], True),
            ("same granule", captures[2], captures[2], True),
            ("stale capacity", captures[1], captures[0], False),
            ("wrong capacity", captures[1],
             captures[1].replace("261616", "261615"), False),
            ("wrong inventory", captures[1],
             captures[1].replace("base_bytes=1073741824", "base_bytes=0"), False),
            ("missing inventory", captures[1],
             "\n".join(captures[1].splitlines()[2:]) + "\n", False),
            ("duplicate inventory", captures[1],
             captures[1] + captures[1].splitlines()[1] + "\n", False),
        ):
            (overlay / "boot.expected").write_text(expected)
            (root / "uart.log").write_text(observed)
            result = subprocess.run(command, capture_output=True, text=True)
            report = result.stdout + result.stderr
            assert (result.returncode == 0) == success, (name, report)
            assert ("PASS control view: boot" if success else
                    "FAIL control view: boot") in report, (name, report)
            assert result.returncode == (0 if success else 1), (name, report)
            cases += 1

        checker = load_checker()
        checker.REPO = root
        path = root / "kernel/tests/qemu/views/boot.expected"
        path.parent.mkdir(parents=True)
        checker.nm_symbols = lambda _elf: {"usable_ram_start": 0x40208000}
        for bad in (template.replace("<allocator_pages>", "261624"),
                    template.replace("<allocator_pages>", ""),
                    template + template.splitlines()[1] + "\n"):
            path.write_text(bad)
            status, report = run_main(checker, "--qemu-boot-expected", "image.elf")
            assert status != 0 and "exactly one memory line" in report, report
            cases += 1
        path.write_text(template)
        for symbols, diagnostic in (
            ({}, "usable_ram_start is absent"),
            ({"usable_ram_start": 0x40208001}, "page-aligned span"),
            ({"usable_ram_start": 0x80000000}, "page-aligned span"),
            ({"usable_ram_start": 0x00208000}, "outside QEMU RAM"),
        ):
            checker.nm_symbols = lambda _elf, symbols=symbols: symbols
            status, report = run_main(checker, "--qemu-boot-expected", "image.elf")
            assert status != 0 and diagnostic in report, report
            cases += 1
    report_pass("QEMU boot capacity controls",
                "linked growth renders exact capacity; shared views reject "
                "stale counts and damaged inventory; invalid templates and "
                "ELF boundaries fail", cases=cases)
    return 0


def link_image(root, base, size):
    """Link an image whose usable_ram_start really comes from the linker."""
    script = root / "layout.ld"
    script.write_text(f"SECTIONS {{ . = {base:#x}; .bss : {{ *(.bss) }} "
                      "usable_ram_start = ALIGN(0x8000); }\n")
    asm = root / "image.s"
    obj = root / "image.o"
    elf = root / f"image-{base:x}-{size:x}.elf"
    asm.write_text(f".bss\n.skip {size}\n")
    for command in (
        ["llvm-mc-19", "-triple=aarch64", "-filetype=obj", str(asm),
         "-o", str(obj)],
        ["ld.lld-19", "-T", str(script), str(obj), "-o", str(elf)],
    ):
        subprocess.run(command, check=True, capture_output=True)
    return elf


def rpi5_boot_controls():
    """The board's boot view renders and compares like QEMU's, off the board."""
    cases = 0
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        template = (ROOT / "kernel/tests/rpi5/views/boot.expected").read_text()
        overlay = root / "overlay"
        platform = root / "platform"
        common = root / "common"
        artifacts = root / "artifacts"
        for path in (overlay, platform, common, artifacts):
            path.mkdir()
        (platform / "boot.filter").write_bytes(
            (ROOT / "kernel/tests/rpi5/views/boot.filter").read_bytes())
        (platform / "boot.expected").write_text(template)
        renders = []
        # Written out, not computed with the checker's helper: (0x3FC00000 -
        # 0x408000) / 4096, and eight pages fewer across a 32 KiB granule.
        for size, pages in ((0x8000, 260088), (0x9000, 260080)):
            result = subprocess.run(
                [sys.executable, str(CHECKER), "--rpi5-boot-expected",
                 str(link_image(root, 0x400000, size))],
                capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            assert result.stdout == template.replace(
                "<allocator_pages>", str(pages)), result.stdout
            renders.append(result.stdout)
            cases += 1
        command = ["bash", "-c", 'source "$1"; kernel_views_compare control '
                   '"$2" "$3" "$4" "$5" "$6"', "control",
                   str(ROOT / "scripts/kernel_views.sh"), str(artifacts),
                   str(root / "uart.log"), str(common), str(platform),
                   str(overlay)]
        for name, expected, observed, success in (
            ("rendered", renders[0], renders[0], True),
            ("stale capacity", renders[1], renders[0], False),
            ("wrong capacity", renders[0],
             renders[0].replace("260088", "260087"), False),
        ):
            (overlay / "boot.expected").write_text(expected)
            (root / "uart.log").write_text(observed)
            result = subprocess.run(command, capture_output=True, text=True)
            report = result.stdout + result.stderr
            assert (result.returncode == 0) == success, (name, report)
            cases += 1
        result = subprocess.run(
            [sys.executable, str(CHECKER), "--rpi5-boot-expected",
             str(link_image(root, 0x1000, 0x1000))],
            capture_output=True, text=True)
        assert result.returncode != 0 and "outside RPi5 RAM" in result.stderr, (
            result.stderr)
        cases += 1
    report_pass("RPi5 boot capacity controls",
                "linked growth renders exact capacity; shared views reject "
                "stale and wrong counts; an image below RAM fails", cases=cases)
    return 0


def fdt_lane_controls():
    """The FDT lane's own matcher against its own rendered lines."""
    spec = importlib.util.spec_from_file_location(
        "fdt_multibank", ROOT / "kernel/tests/check_fdt_multibank_qemu.py")
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)

    def uart(text):
        return subprocess.Popen(
            [sys.executable, "-c",
             f"import sys; sys.stdout.buffer.write({text!r})"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    cases = 0
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base = driver.rendered_memory_lines(link_image(root, 0x40200000, 0x8000))
        grown = driver.rendered_memory_lines(link_image(root, 0x40200000, 0x9000))
        # Written out, from a start of 0x40208000 and the three RAM layouts.
        for name, pages, grown_pages in (
            ("MULTIBANK_EXPECTED", 261624, 261616),
            ("LOW_MEMORY_EXPECTED", 32248, 32240),
            ("DISCONTIGUOUS_MEMORY_EXPECTED", 196088, 196080),
        ):
            line = base[name]
            assert line.endswith(b" allocator_pages=%d\n" % pages), line
            assert grown[name].endswith(
                b" allocator_pages=%d\n" % grown_pages), grown[name]
            cases += 1
            for label, observed, success in (
                ("rendered", line, True),
                ("stale image", grown[name], False),
                ("one page short", line.replace(b"%d\n" % pages,
                                                b"%d\n" % (pages - 1)), False),
                ("extra digit", line.replace(b"%d\n" % pages,
                                             b"%d0\n" % pages), False),
            ):
                found, _ = driver.observe_process(uart(observed), line)
                assert found == success, (name, label, observed)
                cases += 1
    report_pass("FDT lane allocator controls",
                "rendered lines match; stale, short and extra-digit counts "
                "are not found", cases=cases)
    return 0


def main():
    checker = load_checker()
    qemu_start = 0x40200000
    rpi5_start = 0x00400000

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

        write_fixtures(root)
        positive_status, positive_output = run_main(checker)
        if positive_status != 0:
            print("FAIL kernel-memory-map control: current fixtures failed")
            print(positive_output, end="")
            return 1

        # A count written back by hand is the mistake this template replaced.
        write_fixtures(root, rpi5_pages=259120)
        negative_status, negative_output = run_main(checker)
        expected = "must contain exactly one memory line"
        if negative_status == 0:
            print("FAIL kernel-memory-map control: hand-kept count succeeded")
            return 1
        if expected not in negative_output:
            print("FAIL kernel-memory-map control: wrong diagnostic")
            print(negative_output, end="")
            return 1

    report_pass(
        "kernel-memory-map controls",
        "rendered templates pass and a hand-kept count fails",
        cases=CASES.ran)
    # A fresh module: the allocator control above stubs out the very
    # functions these controls exist to exercise.
    status = (qemu_boot_controls() or rpi5_boot_controls() or
              fdt_lane_controls())
    return status if status else layout_controls(load_checker())


if __name__ == "__main__":
    sys.exit(main())
