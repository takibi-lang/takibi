#!/usr/bin/env python3
"""Drive workload.c over serial and query its Linux observer over a second UART."""
import argparse
import re
import socket
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uart', type=int, required=True)
    parser.add_argument('--control', type=int, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--uart-log', type=Path, required=True)
    args = parser.parse_args()
    with socket.create_connection(('127.0.0.1', args.uart)) as uart:
        uart.settimeout(1)
        # QEMU creates the second listener after the waiting first UART connects.
        for attempt in range(100):
            try:
                ctl = socket.create_connection(('127.0.0.1', args.control))
                break
            except ConnectionRefusedError:
                time.sleep(0.1)
        else:
            raise RuntimeError('control UART did not open')
        buf = b''
        pending = []
        parent = None
        completed = False
        deadline = time.monotonic()+120
        with ctl, args.uart_log.open('wb', buffering=0) as log, args.capture.open('w', buffering=1) as capture:
            while time.monotonic() < deadline:
                try:
                    data = uart.recv(65536)
                except socket.timeout:
                    continue
                if not data:
                    break
                log.write(data)
                buf += data
                while b'\n' in buf:
                    raw, buf = buf.split(b'\n', 1)
                    line = re.sub(r'^\[\s*[\d.]+\]\s*', '', raw.decode(errors='replace').strip())
                    if line.startswith('service replay:'):
                        capture.write(line+'\n')
                        match = re.fullmatch(r'service replay: count=(\d+) phase=(\w+) pid=(\d+)', line)
                        if match:
                            _, phase, pid = match.groups()
                            if phase == 'baseline':
                                parent = pid
                            pending = [parent, pid] if phase == 'inherited' else [pid]
                            ctl.sendall((pending[0]+'\n').encode())
                        if line == 'service replay: status=0':
                            completed = True
                    elif line.startswith('service space:'):
                        capture.write(line+'\n')
                        if not pending or ' pid='+pending[0]+' ' not in line:
                            raise RuntimeError('unexpected actor observation')
                        pending.pop(0)
                        if pending:
                            ctl.sendall((pending[0]+'\n').encode())
                        else:
                            uart.sendall(b'\n')
                if completed:
                    break
            if not completed:
                raise RuntimeError('Linux capture lacks successful completion')


if __name__ == '__main__':
    main()
