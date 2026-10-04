#!/usr/bin/env python3
"""Deterministic controls for the shared live/offline QEMU DDB predicates.

Reduced real captures keep the two BREAK sources' evidence independent of
what the validator happens to ask. No QEMU, port, board or lease is opened.
"""

import contextlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import ddb_qemu_checks as checks
import validate_kernel_ddb_qemu as validator
from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts/fixtures"
CASES = CaseCount()


def run(text, metadata, hold, expected=None, *, external=False):
    CASES.note()
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / "uart.txt").write_text(text, encoding="ascii")
        (root / "metadata.json").write_text(json.dumps(metadata), encoding="ascii")
        (root / "hold.txt").write_text(hold, encoding="ascii")
        output = io.StringIO()
        arguments = ["--log", str(root / "uart.txt"),
                     "--metadata", str(root / "metadata.json"),
                     "--hold-log", str(root / "hold.txt")]
        if external:
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/validate_kernel_ddb_qemu.py"), *arguments],
                capture_output=True, text=True, timeout=5)
            status = result.returncode
            output.write(result.stdout + result.stderr)
        else:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                status = validator.main(arguments)
    if expected is None:
        if status != 0 or "capture predicates satisfied" not in output.getvalue():
            raise SystemExit("FAIL ddb-qemu capture positive: " + output.getvalue())
    elif status == 0 or any(part not in output.getvalue() for part in
                            ([expected] if isinstance(expected, str) else expected)):
        raise SystemExit(f"FAIL ddb-qemu capture negative {expected}: status={status}, {output.getvalue()}")


def main():
    for source in ("uart", "software"):
        text = (FIXTURES / f"ddb_qemu_{source}.txt").read_text(encoding="ascii")
        metadata = json.loads((FIXTURES / f"ddb_qemu_{source}.json").read_text(encoding="ascii"))
        hold = (FIXTURES / "ddb_qemu_uart_hold.txt").read_text(encoding="ascii") if source == "uart" else ""
        run(text, metadata, hold, external=True)
        run(text.replace("\n", "\r\n"), metadata, hold.replace("\n", "\r\n"))
        replacements = {"entry": "irq" if source == "uart" else "brk",
                        "source": "33" if source == "uart" else "21579",
                        "address": f'{metadata["kernel_address"]:x}',
                        "sigset": checks.SIGNALS}
        for name, expression, minimum, maximum, applies in checks.REQUIREMENTS:
            if applies not in (source, "both"):
                continue
            for key, value in replacements.items():
                expression = expression.replace("{" + key + "}", value)
            missing = re.sub(expression, "", text, flags=re.MULTILINE)
            if missing == text:
                raise SystemExit("FAIL ddb-qemu capture fixture does not exercise " + name)
            run(missing, metadata, hold, name)
            if maximum is not None:
                extra = re.search(expression, text, re.MULTILINE).group(0)
                run(text + extra + "\n", metadata, hold, name)
        for wrong, diagnosis in (({**metadata, "kernel_address": metadata["kernel_address"] + 1}, "kernel read address"),
                                 ({**metadata, "break_source": "invalid"}, "validation inputs"),
                                 ({**metadata, "kernel_address": -1}, "validation inputs"),
                                 ([], "validation inputs")):
            run(text, wrong, hold, diagnosis)
        if source == "uart":
            for mutated, witness, diagnosis in (
                    (text, "", "console BREAK injection"),
                    (text.replace("masked=sigint", "masked=none"), hold, "PID 1 signal mask"),
                    (re.sub(r"^ddb: wait pid=[0-9]+ state=blocked waits-for event=uart-rx queued=[0-9]+$", "", text, flags=re.MULTILINE), hold, "peer terminal reader"),
                    (text.replace("workload: peer tty read its 17-byte line", "missing delivery"), hold, "peer terminal delivery"),
                    (text.replace("ddb: stacks roots=", "missing roots="), hold, "migration stack attribution"),
                    (text.replace("workload: busy pair migrated across both cpus with stack handoff intact\n", "") + "workload: busy pair migrated across both cpus with stack handoff intact\n", hold, "snapshot ordering")):
                run(mutated, metadata, witness, diagnosis)
        else:
            run(text, {**metadata, "generated_end": metadata["generated_start"]}, hold, "validation inputs")
            run(text, {**metadata, "generated_start": 1, "generated_end": 2}, hold, "compiler frame outside")
            run(text.replace("boundary=assembly-bridge", "boundary=user"), metadata, hold, "backtrace root")
            run(text.replace("ddb: stack cpu=1 status=idle", "missing idle"), metadata, hold, "boot idle root")
        # Several independent missing fields must be reported in one invocation.
        run(text.replace("ddb: world-stop complete", "missing stop").replace("ddb: console tx=queued", "missing queue"),
            metadata, hold, ["world stop acknowledgement", "console queued after continue"], external=True)
    report_pass("ddb-qemu capture controls", "live/offline predicates accept both BREAK sources and LF/CRLF; missing requirements, wrong addresses, masks, roots, transport evidence and ordering are refused with their own diagnoses", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
