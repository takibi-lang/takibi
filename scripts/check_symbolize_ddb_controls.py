#!/usr/bin/env python3
"""Controls for exact-identity EL0 top-PC interpretation, including PIE and refusal."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

from pass_line import CaseCount, report_pass
import symbolize_ddb as reader


def main():
    cases = CaseCount()
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        source = root / "image.c"
        source.write_text("__attribute__((noinline)) int sampled(void) { return 7; }\nint main(void) { return sampled(); }\n", encoding="ascii")
        for pie in (False, True):
            elf = root / ("pie" if pie else "exec")
            subprocess.run(["cc", "-g", "-fPIE" if pie else "-fno-pie",
                            "-pie" if pie else "-no-pie", str(source), "-o", str(elf)],
                           check=True, timeout=4)
            data = elf.read_bytes()
            _, entry, segments, _ = reader.executable(data)
            nm = subprocess.run(["nm", str(elf)], check=True, capture_output=True,
                                text=True, timeout=2).stdout
            address = int(next(line.split()[0] for line in nm.splitlines()
                               if line.endswith(" T sampled")), 16)
            bias = 0x80000000 if pie else 0
            capture = root / "postmortem.log"
            original = (f"ddb: bt source=cpu cpu=0 pid=7 stack=0x0..0x1000\n"
                        f"ddb: bt frame=0 pc=0x{address+bias:x} boundary=user\n"
                        "ddb: bt stop=user-boundary fp=0x0\n"
                        "ddb: bt source=saved pid=8 stack=0x0..0x1000\n"
                        f"ddb: bt frame=0 pc=0x{address+bias:x} boundary=user\n"
                        "ddb: bt source=cpu cpu=1 pid=9 stack=0x0..0x1000\n"
                        f"ddb: bt frame=0 pc=0x{address:x}\n")
            mapping = root / "map.json"
            record = {"pid": 7, "elf": str(elf), "sha256": hashlib.sha256(data).hexdigest(),
                      "load_bias": bias, "runtime_entry": entry + bias,
                      "load_evidence": "Fixture loader registration; entry retained independently of the bias."}

            def run(name, *, replacement=None, text=original, raw_data=None, capture_sha=None):
                cases.note()
                capture.write_text(text, encoding="ascii")
                if raw_data is not None:
                    elf.write_bytes(raw_data)
                else:
                    elf.write_bytes(data)
                registration = record.copy() if replacement is None else replacement
                manifest = {"schema": "takibi.ddb.elf-map/v1",
                            "capture_sha256": capture_sha or hashlib.sha256(capture.read_bytes()).hexdigest(),
                            "processes": [registration]}
                mapping.write_text(json.dumps(manifest), encoding="ascii")
                output = root / (("pie-" if pie else "exec-") + name)
                status = reader.collect(capture, mapping, output, "llvm-addr2line-19", 2)
                report = json.loads((output / "symbols.json").read_text())
                assert (output / "postmortem.raw.log").read_bytes() == capture.read_bytes()
                return status, report, output

            status, report, output = run("good")
            assert status == 0 and len(report["rows"]) == 2
            assert report["rows"][0]["symbol"]["function"] == "sampled"
            assert report["rows"][0]["linked_pc"] == address
            assert report["rows"][1]["status"] == "unresolved"
            assert report["rows"][1]["reason"] == "unknown PID-to-ELF mapping"
            saved = output / "elfs" / (record["sha256"] + ".elf")
            assert saved.read_bytes() == data
            elf.unlink()
            assert reader.symbolize("llvm-addr2line-19", str(saved), [address], 2)[0]["function"] == "sampled"
            for name, changes, reason in (
                    ("identity", {"sha256": "0"*64}, "ELF identity mismatch"),
                    ("missing", {"elf": str(root / "absent")}, "No such file"),
                    ("bias", {"load_bias": bias + 4096}, "load bias disagrees"),
                    ("entry", {"runtime_entry": entry + bias + 1}, "load bias disagrees"),
                    ("evidence", {"load_evidence": ""}, "missing external load evidence")):
                status, report, _ = run(name, replacement={**record, **changes})
                assert status == 1 and report["rows"][0]["status"] == "refused", "a mismatched registration was accepted"
                assert reason in report["rows"][0]["reason"], report
            for name, damaged in (("truncated-header", data[:63]),
                                  ("truncated-segment", data[:100])):
                registration = {**record, "sha256": hashlib.sha256(damaged).hexdigest()}
                status, report, _ = run(name, replacement=registration, raw_data=damaged)
                assert status == 1 and "truncated" in report["rows"][0]["reason"]
            status, report, _ = run("replaced-identity", raw_data=data + b"replacement")
            assert status == 1 and "ELF identity mismatch" in report["rows"][0]["reason"], "a replaced ELF was accepted"
            status, report, _ = run("duplicate-context", text=original.replace("pid=7 stack=", "pid=7 pid=8 stack="))
            assert report["rows"][0]["status"] == "unresolved"
            status, report, _ = run("kernel-boundary", text=original.replace("boundary=user", "boundary=kernel"))
            assert report["rows"] == []
            bad_pc = next(end for _, end in segments)
            status, report, _ = run("outside", text=original.replace(
                f"pc=0x{address+bias:x}", f"pc=0x{bad_pc+bias:x}", 1))
            assert status == 1 and "outside executable" in report["rows"][0]["reason"]
            status, report, _ = run("no-context", text=f"ddb: bt frame=0 pc=0x{address+bias:x} boundary=user\n")
            assert status == 0 and report["rows"][0]["pid"] is None
            assert report["rows"][0]["status"] == "unresolved"
            status, report, _ = run("stopped", text=original.replace("source=cpu cpu=0", "source=stopped cpu=0"))
            assert status == 0 and report["rows"][0]["status"] == "resolved"
            with patch.object(reader, "symbolize", side_effect=ValueError("symbolizer timed out")):
                status, report, _ = run("symbolizer")
            assert status == 1 and "timed out" in report["rows"][0]["reason"]
            try:
                run("wrong-capture", capture_sha="0"*64)
            except ValueError as error:
                assert "exact postmortem" in str(error)
            else:
                raise AssertionError("a mapping for another capture was accepted")
    report_pass("symbolize-ddb-controls", "PIE and fixed ELF identities, bias anchors, executable segments, user boundaries and archived bytes", cases=cases.ran)


if __name__ == "__main__":
    main()
