#!/usr/bin/env python3
"""Exercise the churn reader and injection against actual compiled QEMU storage.

Seeded, stopped globals verify decoding and refusal, not natural protocol timing.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time

from capture_kernel_console import qmp
from churn_gdb import ChurnGdb


ROOT = Path(__file__).resolve().parent.parent
ELF = ROOT / "kernel/build/qemu/kernel.elf"


def main():
    artifact = Path(os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT", ROOT / "_build")) / "kernel-churn-gdb-qemu"
    artifact.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tk-churn-test-") as temporary:
        directory = Path(temporary)
        helper = ChurnGdb(artifact, ELF)
        helper.qmp_socket = directory / "qmp"
        with (artifact / "qemu.log").open("w") as output:
            guest = subprocess.Popen([
                "qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a53",
                "-smp", "4", "-m", "1024", "-display", "none", "-monitor", "none",
                "-serial", "none", "-S", "-qmp",
                f"unix:{helper.qmp_socket},server=on,wait=off", "-kernel", str(ELF)],
                stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 5
                while not helper.qmp_socket.is_socket():
                    if guest.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("QEMU did not open its QMP socket")
                    time.sleep(.01)
                helper.open()
                script = directory / "seed.gdb"

                def seed(held):
                    script.write_text('''maintenance packet Qqemu.PhyMemMode:1
python
import re
with open("''' + str(ROOT / "_build/kernel-churn-layout.gdb") + '''") as stream:
    layout = {key: int(value) for key, value in re.findall(r"^set \\$takibi_(\\S+) = ([0-9]+)$", stream.read(), re.M)}
def addr(name): return int(gdb.parse_and_eval('&' + name))
def put(base, value): gdb.selected_inferior().write_memory(base, value.to_bytes(8, 'little'))
cell = addr('asid_cell')
put(cell + layout['lockedcell$asidstate_value'] + layout['asidstate_next'], 100)
put(cell + layout['lockedcell$asidstate_lock'] + layout['mutex_word'], ''' + str(held) + ''')
put(addr('asid_last'), 65535)
end
maintenance packet Qqemu.PhyMemMode:0
disconnect
''', encoding="ascii")
                    result = subprocess.run(["gdb-multiarch", "-nx", "-q", "-batch", str(ELF),
                                             "-ex", f"target remote {helper.endpoint}", "-x", str(script)],
                                            capture_output=True, text=True, timeout=10)
                    assert result.returncode == 0 and "Error" not in result.stderr, result.stdout + result.stderr

                seed(0)
                assert helper.run()
                text = (artifact / "gdb-stall.log").read_text()
                assert '"acks": [0, 0, 0, 0]' in text and '"asid_next": 100' in text, text
                assert "Thread 4" in text and "cpsr" in text, text
                assert helper.run(65000)
                try:
                    helper.run(65000)
                except RuntimeError:
                    assert "must advance the current counter" in (artifact / "asid-jump.log").read_text()
                else:
                    raise AssertionError("ASID rewind was accepted")
                seed(1)
                assert helper.run(65000) is False, "ASID injection accepted a held cell lock"
                assert not qmp(helper.qmp_socket, "query-status")["running"]
                helper.close()
                helper.open()
                assert helper.run()
                helper.close()
            finally:
                helper.close()
                guest.terminate()
                try:
                    guest.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    guest.kill()
                    guest.wait()
    print("PASS kernel/qemu churn-gdb: four CPUs, typed layout, forward-only ASID jump and lock refusal")


if __name__ == "__main__":
    main()
