#!/usr/bin/env python3
"""Archive and symbolize captured EL0 top PCs with explicitly registered ELF identities."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys

from profile_kernel_samples import elf_identity, fields, symbolize


U64 = (1 << 64) - 1


def number(value):
    result = int(value, 0) if isinstance(value, str) else value
    if isinstance(result, bool) or not isinstance(result, int) or not 0 <= result <= U64:
        raise ValueError("invalid unsigned address")
    return result


def executable(data):
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("missing or truncated ELF64 little-endian header")
    kind, machine, version, entry, phoff = struct.unpack_from("<HHIQQ", data, 16)
    ehsize, phsize, phcount = struct.unpack_from("<HHH", data, 52)
    if kind not in (2, 3) or machine not in (62, 183) or version != 1 or ehsize != 64:
        raise ValueError("unsupported ELF header")
    if phsize != 56 or not phcount or phoff < 64 or phoff + phcount * phsize > len(data):
        raise ValueError("truncated ELF program headers")
    segments = []
    for index in range(phcount):
        tag, flags, offset, address, _, filesz, memsz, alignment = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + index * phsize)
        if tag != 1:
            continue
        if filesz > memsz or offset + filesz > len(data) or address + memsz > U64:
            raise ValueError("truncated or invalid ELF load segment")
        if alignment not in (0, 1) and (alignment & (alignment - 1) or address % alignment != offset % alignment):
            raise ValueError("invalid ELF load alignment")
        if flags & 1 and filesz:
            segments.append((address, address + filesz))
    if not any(start <= entry < end for start, end in segments):
        raise ValueError("ELF entry is outside executable file-backed segments")
    return kind, entry, segments, (4 if machine == 183 else 1)


def top_pcs(raw):
    context = None
    rows = []
    for line in raw.decode("ascii", "replace").replace("\r", "").splitlines():
        if "ddb: bt source=" in line:
            context = None
            try:
                record = fields(line.partition("ddb: bt ")[2])
                if record["source"] not in ("cpu", "stopped", "saved"):
                    continue
                pid = number(record["pid"])
                if record["source"] != "saved" and not 0 <= number(record["cpu"]) < 64:
                    continue
                context = pid if pid else None
            except (KeyError, ValueError):
                pass
        elif "ddb: bt frame=0 " in line:
            if re.search(r"\bboundary=user(?:\s|$)", line):
                try:
                    record = fields(line.partition("ddb: bt ")[2])
                    pc = number(record["pc"])
                except (KeyError, ValueError):
                    pc = None
                rows.append({"pid": context, "pc": pc})
            context = None
        elif line.strip() == "ddb>" or "ddb: bt stop=" in line:
            context = None
    return rows


def archive_file(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError("archive path contains different bytes: " + str(path))
    else:
        with path.open("xb") as stream:
            stream.write(data)


def collect(postmortem, mapping, output, tool, timeout):
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("symbolizer timeout must be finite and positive")
    raw = Path(postmortem).read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    manifest_path = Path(mapping).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="ascii"))
    if not isinstance(manifest, dict) or manifest.get("schema") != "takibi.ddb.elf-map/v1" or manifest.get("capture_sha256") != digest:
        raise ValueError("ELF map does not identify this exact postmortem")
    records = manifest.get("processes")
    if not isinstance(records, list):
        raise ValueError("ELF map needs a processes list")
    out = Path(output)
    archive_file(out / "postmortem.raw.log", raw)
    mappings = {}
    refused = False
    for record in records:
        pid = number(record["pid"])
        if not pid or pid in mappings:
            raise ValueError("duplicate or invalid PID mapping")
        try:
            expected = record["sha256"]
            if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                raise ValueError("missing expected ELF SHA256")
            evidence = record.get("load_evidence")
            if not isinstance(evidence, str) or not evidence.strip() or not evidence.isascii():
                raise ValueError("missing external load evidence")
            bias = number(record["load_bias"])
            runtime_entry = number(record["runtime_entry"])
            source = Path(record["elf"])
            if not source.is_absolute():
                source = manifest_path.parent / source
            data = source.read_bytes()
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError("ELF identity mismatch")
            kind, entry, segments, instruction_alignment = executable(data)
            if (kind == 2 and bias != 0) or bias % 4096 or entry + bias > U64 or entry + bias != runtime_entry:
                raise ValueError("load bias disagrees with registered runtime entry")
            if any(end + bias > U64 for _, end in segments):
                raise ValueError("relocated executable segment overflows")
            saved = out / "elfs" / (expected + ".elf")
            archive_file(saved, data)
            identity = elf_identity(saved)
            identity["source"] = str(source.resolve())
            mappings[pid] = {"identity": identity, "bias": bias, "runtime_entry": runtime_entry,
                             "load_evidence": evidence, "segments": segments,
                             "instruction_alignment": instruction_alignment, "elf": str(saved)}
        except (KeyError, ValueError, OSError) as error:
            mappings[pid] = {"refusal": str(error)}
            refused = True
    rows = top_pcs(raw)
    for row in rows:
        row.update(status="unresolved", symbol=None)
        registered = mappings.get(row["pid"])
        if registered is None:
            row["reason"] = "unknown PID-to-ELF mapping"
            continue
        if "refusal" in registered:
            row.update(status="refused", reason=registered["refusal"])
            continue
        row.update(elf=registered["identity"], load_bias=registered["bias"],
                   runtime_entry=registered["runtime_entry"], load_evidence=registered["load_evidence"])
        pc = row["pc"]
        if pc is None or not registered["bias"] <= pc <= U64 or pc % registered["instruction_alignment"]:
            row.update(status="refused", reason="invalid captured user PC")
            refused = True
            continue
        linked_pc = pc - registered["bias"]
        if not any(start <= linked_pc < end for start, end in registered["segments"]):
            row.update(status="refused", reason="PC is outside executable file-backed load segments")
            refused = True
            continue
        row["linked_pc"] = linked_pc
        try:
            symbol = symbolize(tool, registered["elf"], [linked_pc], timeout)[0]
            if symbol["function"] is None:
                row["reason"] = "symbol unavailable in the registered ELF"
            else:
                row.update(status="resolved", symbol=symbol)
        except ValueError as error:
            row.update(status="refused", reason=str(error))
            refused = True
    report = {"schema": "takibi.ddb.el0-top-pc/v1", "capture_sha256": digest,
              "capture": "postmortem.raw.log", "rows": rows,
              "mappings": [{"pid": pid, **{key: value for key, value in registration.items()
                                           if key not in ("segments", "elf")}}
                           for pid, registration in sorted(mappings.items())]}
    out.mkdir(parents=True, exist_ok=True)
    (out / "symbols.json").write_text(json.dumps(report, indent=2) + "\n", encoding="ascii")
    return 1 if refused else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--postmortem", required=True)
    parser.add_argument("--elf-map", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--symbolizer", default="llvm-addr2line-19")
    parser.add_argument("--symbolizer-timeout", type=float, default=5)
    args = parser.parse_args()
    if not math.isfinite(args.symbolizer_timeout) or args.symbolizer_timeout <= 0:
        parser.error("symbolizer-timeout must be finite and positive")
    try:
        return collect(args.postmortem, args.elf_map, args.output,
                       args.symbolizer, args.symbolizer_timeout)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("DDB symbolization refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
