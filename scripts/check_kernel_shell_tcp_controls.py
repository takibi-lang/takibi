#!/usr/bin/env python3
"""Offline controls for checksum-verified post-boot HTTP measurements."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

from measure_kernel_shell_tcp import measure_bulk
from pass_line import CaseCount, report_pass


class Reply(io.BytesIO):
    def __init__(self, body, status=200):
        super().__init__(body)
        self.status = status


def scenario(kind):
    with tempfile.TemporaryDirectory() as name:
        root = Path(name)
        user = root / "kernel/build/user"
        user.mkdir(parents=True)
        (user / "busybox-extras").write_bytes(b"extras")
        (user / "busybox-static").write_bytes(b"static")
        elf = root / "kernel/build/rpi5/kernel-shell.elf"
        elf.parent.mkdir(parents=True)
        elf.write_bytes(b"ELF")
        ticks = iter(range(0, 100000000000, 1000000000))

        class Opener:
            def open(self, url, timeout):
                assert timeout == 60
                body = b"extras" if url.endswith("busybox-extras") else b"static"
                if kind == "corrupt": body = b"broken"
                if kind == "short": body = body[:-1]
                if kind == "long": body += b"x"
                if kind == "transport": raise OSError("connection stopped")
                if kind == "changed-elf": elf.write_bytes(b"different ELF")
                return Reply(body, 500 if kind == "http-error" else 200)

        failed = False
        clock = (lambda: 1) if kind == "zero-time" else (lambda: next(ticks))
        with patch("measure_kernel_shell_tcp.urllib.request.build_opener", return_value=Opener()), \
             patch("measure_kernel_shell_tcp.time.monotonic_ns", side_effect=clock), \
             contextlib.redirect_stdout(io.StringIO()):
            try:
                measure_bulk("http://board/", root, root,
                             expected_elf_digest="wrong" if kind == "changed-after-launch" else None)
            except (OSError, RuntimeError):
                failed = True
        artifact = json.loads((root / "bulk-tcp.json").read_text())
        if kind == "healthy":
            assert not failed and artifact["status"] == "PASS"
            assert len(artifact["runs"]) == 8
            assert sum(row["warmup"] for row in artifact["runs"]) == 2
            assert all(row["seconds"] == 1 and row["bytes"] == 6
                       for row in artifact["runs"])
            assert len(list(root.glob("bulk-*.body"))) == 8
        else:
            assert failed and artifact["status"] == "FAIL" and artifact["error"]
            if kind == "changed-elf": assert len(artifact["runs"]) == 8


def main():
    cases = CaseCount()
    for kind in ("healthy", "corrupt", "short", "long", "http-error",
                 "transport", "zero-time", "changed-elf", "changed-after-launch"):
        cases.note()
        scenario(kind)
    report_pass("kernel-shell-tcp controls",
                "warm-up is separate; body, transport, clock and ELF failures retain a failed artifact",
                cases=cases.ran)


if __name__ == "__main__":
    main()
