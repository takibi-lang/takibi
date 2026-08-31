#!/usr/bin/env python3
"""Inventory explicit trusted boundaries in the maintained kernel build.

The source set comes from depfiles emitted by successful --forbid-trap builds.
This is an audit aid, not a proof: TRUSTED_BASE.md records the assumptions that
cannot be counted.
"""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
KERNEL_DIR = REPO_ROOT / "kernel"


def read_depfile_sources(depfile: Path) -> list[str]:
    if not depfile.exists():
        sys.exit(f"error: {depfile} does not exist -- run `make kernelbuild` first")
    text = depfile.read_text().replace("\\\n", " ")
    _, _, prereqs = text.partition(":")
    return sorted(set(p for p in prereqs.split() if p.endswith(".tkb")))


def count_lines(paths: list[Path]) -> int:
    return sum(len(path.read_text().splitlines()) for path in paths)


def code_tokens(text: str) -> list[tuple[str, int, int]]:
    """Return code tokens while skipping lexer-equivalent comments/literals."""
    tokens = []
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if ch.isspace():
            i += 1
        elif ch == "/" and nxt == "/":
            newline = text.find("\n", i + 2)
            i = len(text) if newline < 0 else newline + 1
        elif ch == "/" and nxt == "*":
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
        elif ch in {'"', "'"}:
            start = i
            quote = ch
            i += 1
            while i < len(text):
                if text[i] == "\\":
                    i = min(i + 2, len(text))
                elif text[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            tokens.append(("literal", start, i))
        elif ch.isalpha() or ch == "_":
            start = i
            i += 1
            while i < len(text) and (text[i].isalnum() or text[i] == "_"):
                i += 1
            tokens.append((text[start:i], start, i))
        else:
            tokens.append((ch, i, i + 1))
            i += 1
    return tokens


def unsafe_blocks(path: Path) -> list[tuple[int, str]]:
    """Return real unsafe-block line/body pairs from one lexical token pass."""
    text = path.read_text()
    tokens = code_tokens(text)
    result = []
    for index, (token, start, _) in enumerate(tokens):
        if token != "unsafe" or index + 1 >= len(tokens):
            continue
        if tokens[index + 1][0] != "{":
            continue
        depth = 0
        for closing in range(index + 1, len(tokens)):
            current = tokens[closing][0]
            if current == "{":
                depth += 1
            elif current == "}":
                depth -= 1
                if depth == 0:
                    end = tokens[closing][2]
                    result.append((text.count("\n", 0, start) + 1,
                                   text[start:end]))
                    break
        else:
            sys.exit(f"error: unterminated unsafe block in {path}")
    return result


def classify_unsafe(body: str) -> str:
    if re.search(r"\bas\s+\*io\b", body):
        return "MMIO pointer construction/access"
    if re.search(r"\bas\s+\*", body):
        return "raw memory pointer/cast"
    if "[" in body:
        return "unchecked indexing/slice operation"
    return "unclassified"


def classify_raw_pointer_casts(paths: list[Path]) -> dict[str, int]:
    counts = {"total": 0, "device": 0, "string": 0, "memory": 0}
    for path in paths:
        text = path.read_text()
        for match in re.finditer(r"\bas\s+\*", text):
            counts["total"] += 1
            if text[match.end():match.end() + 3] == "io ":
                counts["device"] += 1
            elif text[:match.start()].rstrip().endswith('"'):
                counts["string"] += 1
            else:
                counts["memory"] += 1
    return counts


def classify_assembly() -> dict[str, list[Path]]:
    result = {"production handwritten": [], "generated": [], "fixture": []}
    paths = sorted(list(KERNEL_DIR.rglob("*.S")) + list(KERNEL_DIR.rglob("*.inc")))
    for path in paths:
        relative = path.relative_to(KERNEL_DIR)
        if "test" in relative.parts or "tests" in relative.parts:
            kind = "fixture"
        elif "GENERATED" in path.read_text()[:512]:
            kind = "generated"
        else:
            kind = "production handwritten"
        result[kind].append(path)
    return result


def count_pattern(paths: list[Path], pattern: str) -> int:
    regex = re.compile(pattern)
    return sum(len(regex.findall(path.read_text())) for path in paths)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true",
                        help="list exact sources and unsafe-site classifications")
    args = parser.parse_args()

    targets = {
        "RPi5 kernel": read_depfile_sources(KERNEL_DIR / "build/rpi5/main.o.d"),
        "QEMU kernel": read_depfile_sources(KERNEL_DIR / "build/qemu/main.o.d"),
        "EL0 test payload": read_depfile_sources(
            KERNEL_DIR / "build/rpi5/user_payload_tkb.o.d"
        ),
    }
    source_names = sorted(set().union(*map(set, targets.values())))
    source_paths = [REPO_ROOT / name for name in source_names]
    outside = sorted(set(KERNEL_DIR.rglob("*.tkb")) - set(source_paths))

    sites: dict[str, list[tuple[Path, int]]] = defaultdict(list)
    for path in source_paths:
        for line, body in unsafe_blocks(path):
            sites[classify_unsafe(body)].append((path, line))
    raw_casts = classify_raw_pointer_casts(source_paths)
    assembly = classify_assembly()

    print("Takibi trusted-boundary inventory")
    print("=================================")
    print("Checked kernel source coverage")
    print(f"  --forbid-trap union : {len(source_paths)} files, {count_lines(source_paths)} lines")
    for target, names in targets.items():
        print(f"  {target:19}: {len(names)} files")
    print(f"  outside that union  : {len(outside)} kernel .tkb files")

    print("Explicit unsafe blocks (primary syntactic rationale)")
    categories = (
        "MMIO pointer construction/access", "raw memory pointer/cast",
        "unchecked indexing/slice operation", "unclassified",
    )
    for category in categories:
        print(f"  {category:36}: {len(sites[category])}")

    print("Other explicit source boundaries")
    print(f"  raw pointer casts                  : {raw_casts['total']}")
    print(f"    memory / MMIO / string           : {raw_casts['memory']} / {raw_casts['device']} / {raw_casts['string']}")
    print(f"  extern function/symbol declarations: {count_pattern(source_paths, r'\bextern\s+(?:fn|symbol)\b')}")
    dma_pattern = r"\b(?:dma_prepare_tx|dma_prepare_rx|dma_finish_rx|dma_publish|dma_consume)\s*\("
    print(f"  DMA/cache builtin operations       : {count_pattern(source_paths, dma_pattern)}")

    print("Assembly boundary")
    for category in ("production handwritten", "generated", "fixture"):
        paths = assembly[category]
        print(f"  {category:24}: {len(paths)} files, {count_lines(paths)} lines")

    if args.verbose:
        print("\nExact --forbid-trap source union")
        for name in source_names:
            print(f"  {name}")
        print("\nKernel .tkb files outside that union")
        for path in outside:
            print(f"  {path.relative_to(REPO_ROOT)}")
        print("\nUnsafe-site classifications")
        for category in sorted(sites):
            for path, line in sites[category]:
                print(f"  {category}: {path.relative_to(REPO_ROOT)}:{line}")


if __name__ == "__main__":
    main()
