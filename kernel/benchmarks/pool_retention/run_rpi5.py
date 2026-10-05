#!/usr/bin/env python3
"""Run alternating measurement ELFs under the wrapper's existing RPi5 lease."""
import argparse
import subprocess
import threading
from pathlib import Path
import serial
from capture import capture

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--elf0', type=Path, required=True)
    parser.add_argument('--elf1', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--serial', required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    for index, retain in enumerate((1, 0, 0, 1, 1, 0)):
        out = args.output/f'{index+1}-retain{retain}'
        out.mkdir()
        print(f'RPi5 retention run {index+1}: retain={retain}', flush=True)
        with (out/'reset.log').open('w') as log:
            reset = subprocess.run([str(ROOT/'scripts/rpi5_jtag_reset.sh'), '--resident-image-unchanged'], stdout=log, stderr=log)
        if reset.returncode:
            raise SystemExit(10)
        error = []
        with serial.Serial(args.serial, 115200, timeout=1) as uart:
            uart.reset_input_buffer()
            def worker():
                try: capture(lambda: uart.read(65536), out/'uart.log', out/'capture.txt')
                except Exception as caught: error.append(caught)
            thread = threading.Thread(target=worker, daemon=True)
            thread.start()
            with (out/'load.log').open('w') as log:
                loaded = subprocess.run([str(ROOT/'scripts/rpi5_jtag_load.sh'), str(args.elf1 if retain else args.elf0)], stdout=log, stderr=log)
            if loaded.returncode:
                raise SystemExit(10)
            thread.join(timeout=245)
            if thread.is_alive():
                raise RuntimeError('capture did not finish')
            if error:
                raise error[0]
        print(f'RPi5 retention run {index+1}: workload and teardown complete', flush=True)


if __name__ == '__main__':
    main()
