#!/usr/bin/env python3
"""Validate retained QEMU DDB evidence without opening a guest or a port."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from ddb_qemu_checks import REQUIREMENTS, capture_problems


def elf_metadata(elf, source):
    symbols = {}
    for line in subprocess.check_output(["llvm-nm-19", str(elf)], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] in (
                "kernel_ddb_breakpoint_test_enabled", "kernel_generated_text_start",
                "kernel_generated_text_end"):
            symbols[fields[2]] = int(fields[0], 16)
    metadata = {"break_source": source,
                "kernel_address": symbols["kernel_ddb_breakpoint_test_enabled"],
                "elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest()}
    if source == "software":
        metadata.update(generated_start=symbols["kernel_generated_text_start"],
                        generated_end=symbols["kernel_generated_text_end"])
    return metadata


def checked_metadata(metadata):
    if not isinstance(metadata, dict):
        raise ValueError("metadata must be a JSON object")
    if metadata.get("break_source") not in ("uart", "software"):
        raise ValueError("metadata requires break_source uart or software")
    fields = ["kernel_address"]
    if metadata["break_source"] == "software":
        fields += ["generated_start", "generated_end"]
    for field in fields:
        if type(metadata.get(field)) is not int or not 0 <= metadata[field] < 2**64:
            raise ValueError(f"metadata requires a 64-bit nonnegative integer {field}")
    if metadata["break_source"] == "software" and metadata["generated_start"] >= metadata["generated_end"]:
        raise ValueError("metadata generated-text bounds are empty")
    return metadata


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--metadata-only", action="store_true",
                        help="save ELF addresses before a live run starts")
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--elf", type=Path)
    inputs.add_argument("--metadata", type=Path)
    parser.add_argument("--break-source", choices=("uart", "software"))
    parser.add_argument("--save-metadata", type=Path)
    parser.add_argument("--hold-log", type=Path,
                        help="UART injection witness; defaults to LOG.hold-gdb.log")
    args = parser.parse_args(argv)
    if args.elf and not args.break_source:
        parser.error("--elf requires --break-source")
    if args.metadata and args.break_source:
        parser.error("--metadata already specifies the BREAK source")
    if args.metadata_only and (not args.elf or not args.save_metadata):
        parser.error("--metadata-only requires --elf and --save-metadata")
    if not args.metadata_only and args.log is None:
        parser.error("capture validation requires --log")
    try:
        metadata = checked_metadata(elf_metadata(args.elf, args.break_source) if args.elf
                                    else json.loads(args.metadata.read_text(encoding="ascii")))
        if args.save_metadata:
            args.save_metadata.write_text(json.dumps(metadata, indent=2) + "\n", encoding="ascii")
        if args.metadata_only:
            return 0
        text = args.log.read_text(encoding="ascii", errors="replace")
        hold_text = ""
        if metadata["break_source"] == "uart":
            hold = args.hold_log or Path(str(args.log) + ".hold-gdb.log")
            if hold.exists():
                hold_text = hold.read_text(encoding="ascii", errors="replace")
        problems = capture_problems(text, metadata, hold_text)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"FAIL kernel/qemu ddb: validation inputs: {error}", file=sys.stderr)
        return 1
    for problem in problems:
        print("FAIL kernel/qemu ddb: " + problem, file=sys.stderr)
    if problems:
        # Retain the existing triage symptom only for failures of the old
        # enclosing shell chain. Individual requirements are printed first.
        if any(problem.startswith(name + ":") for problem in problems
               for name, *_ in REQUIREMENTS):
            print("FAIL kernel/qemu ddb: BREAK inspection did not resume boot "
                  "(individual capture predicates above)", file=sys.stderr)
        return 1
    print(f'PASS kernel/qemu ddb: {metadata["break_source"]} capture predicates satisfied')
    return 0


if __name__ == "__main__":
    sys.exit(main())
