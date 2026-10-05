#!/usr/bin/env python3
"""Capture the real workload's success/exit and both pool accounting windows."""
import argparse
import socket
import time
from pathlib import Path


def capture(read, raw_path, capture_path, timeout=240):
    buf = b''
    begun = done = status = False
    deadline = time.monotonic()+timeout
    with raw_path.open('wb', buffering=0) as raw, capture_path.open('w', buffering=1) as out:
        while time.monotonic() < deadline:
            data = read()
            if not data:
                continue
            raw.write(data)
            buf += data
            while b'\n' in buf:
                part, buf = buf.split(b'\n', 1)
                line = part.decode(errors='replace').strip()
                if line.startswith('retention stats:') or line.startswith('retention workload:'):
                    out.write(line+'\n')
                if line == 'retention workload: begin':
                    if begun: raise RuntimeError('duplicate workload')
                    begun = True
                if line == 'retention workload: done':
                    if not begun or done: raise RuntimeError('invalid completion')
                    done = True
                if line.startswith('init script exit:') and begun:
                    if not done or status or line != 'init script exit: 0':
                        raise RuntimeError('workload did not exit zero')
                    status = True
                    out.write('retention workload: status=0\n')
                if line == 'pool space: end=bounded_end' and status:
                    out.write('retention workload: teardown\n')
                    return
        raise RuntimeError('capture lacks successful workload exit and teardown')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uart', type=int, required=True)
    parser.add_argument('--raw', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    args = parser.parse_args()
    with socket.create_connection(('127.0.0.1', args.uart)) as uart:
        uart.settimeout(1)
        def read():
            try: return uart.recv(65536)
            except socket.timeout: return b''
        capture(read, args.raw, args.capture)


if __name__ == '__main__':
    main()
