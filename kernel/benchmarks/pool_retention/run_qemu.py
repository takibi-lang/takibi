#!/usr/bin/env python3
"""Run one disposable two-core QEMU kernel; timing is recorded, not hardware evidence."""
import argparse
import shutil
import subprocess
import time
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from qemu_vcpu_lease import QEMU, lease  # noqa: E402


def main():
    smp = lease()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--elf', type=Path, required=True)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--uart', type=int, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(args.image, args.output/'ext2.img')
    cmd = [QEMU, '-machine', 'virt', '-cpu', 'cortex-a53', "-smp", str(smp), '-m', '1024', '-display', 'none', '-monitor', 'none', '-chardev', f'socket,id=uart,host=127.0.0.1,port={args.uart},server=on,wait=on', '-serial', 'chardev:uart', '-drive', f'file={args.output}/ext2.img,if=none,format=raw,id=vd0', '-device', 'virtio-blk-device,drive=vd0', '-kernel', str(args.elf)]
    with (args.output/'qemu.log').open('w') as log:
        process = subprocess.Popen(cmd, stdout=log, stderr=log)
        try:
            time.sleep(1)
            if process.poll() is not None:
                raise RuntimeError('QEMU exited before capture; see qemu.log')
            subprocess.run(['python3', str(Path(__file__).with_name('capture.py')), '--uart', str(args.uart), '--raw', str(args.output/'uart.log'), '--capture', str(args.output/'capture.txt')], check=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
