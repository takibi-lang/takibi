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
    return 0


if __name__ == "__main__":
    sys.exit(main())
