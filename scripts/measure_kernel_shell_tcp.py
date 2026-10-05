#!/usr/bin/env python3
"""Measure checksum-verified bulk HTTP transfers from an already booted kernel.

This records host wall time, not CPU classification or a TCP-only profile.
The caller owns the board lease and keeps the serving ELF unchanged.
"""

import hashlib
import json
from pathlib import Path
import time
import urllib.request


def measure_bulk(url, directory, root, *, repetitions=3, expected_elf_digest=None):
    directory = Path(directory)
    root = Path(root)
    elf = root / "kernel/build/rpi5/kernel-shell.elf"
    runs = []
    artifact = {"name": "bulk-tcp", "target": "rpi5",
                "timing": "host HTTP wall time including request and headers",
                "elf_sha256": None, "status": "FAIL", "runs": runs}
    try:
        elf_digest = hashlib.sha256(elf.read_bytes()).hexdigest()
        artifact["elf_sha256"] = elf_digest
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        if expected_elf_digest is not None and elf_digest != expected_elf_digest:
            raise RuntimeError("bulk TCP: serving ELF changed after launch")
        for remote, local in (("busybox-extras", "busybox-extras"),
                              ("busybox.static", "busybox-static")):
            reference = (root / "kernel/build/user" / local).read_bytes()
            expected = hashlib.sha256(reference).hexdigest()
            for iteration in range(repetitions + 1):
                started = time.monotonic_ns()
                with opener.open(url + "bin/" + remote, timeout=60) as response:
                    body = response.read(len(reference) + 1)
                    status = response.status
                finished = time.monotonic_ns()
                digest = hashlib.sha256(body).hexdigest()
                if status != 200 or len(body) != len(reference) or digest != expected:
                    raise RuntimeError(f"bulk TCP {remote}: HTTP status, size, or checksum mismatch")
                elapsed = finished - started
                if elapsed <= 0:
                    raise RuntimeError("bulk TCP: nonpositive elapsed time")
                record = {"path": "/bin/" + remote, "iteration": iteration,
                          "warmup": iteration == 0, "bytes": len(body),
                          "sha256": digest, "started_ns": started,
                          "finished_ns": finished, "seconds": elapsed / 1e9,
                          "bytes_per_second": len(body) * 1e9 / elapsed}
                runs.append(record)
                (directory / f"bulk-{remote}-{iteration}.body").write_bytes(body)
                print(f"[bulk-tcp] {remote} iteration={iteration} "
                      f"warmup={iteration == 0} bytes={len(body)} "
                      f"seconds={elapsed / 1e9:.6f} sha256={digest}", flush=True)
        if hashlib.sha256(elf.read_bytes()).hexdigest() != elf_digest:
            raise RuntimeError("bulk TCP: serving ELF changed during measurement")
        artifact["status"] = "PASS"
        return artifact
    except (OSError, RuntimeError) as error:
        artifact["error"] = str(error)
        raise
    finally:
        (directory / "bulk-tcp.json").write_text(json.dumps(artifact, indent=2) + "\n")
