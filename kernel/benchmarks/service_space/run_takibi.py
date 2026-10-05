#!/usr/bin/env python3
"""Drive the actual kernel syscall workload and take read-only GDB pool samples."""
import argparse
import re
import socket
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uart', type=int, required=True)
    parser.add_argument('--gdb-port', type=int, required=True)
    parser.add_argument('--elf', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--uart-log', type=Path, required=True)
    args = parser.parse_args()
    script = Path(__file__).with_name('sample_takibi.gdb')
    def sample():
        result = subprocess.run(['gdb-multiarch', '-q', '-batch', str(args.elf),
                                 '-ex', f'target remote 127.0.0.1:{args.gdb_port}', '-x', str(script)],
                                capture_output=True, text=True, check=True, timeout=30)
        lines = [line for line in result.stdout.splitlines() if line.startswith('service pools:')]
        if len(lines) != 1:
            raise RuntimeError('GDB did not produce exactly one pool sample')
        return lines[0]
    with socket.create_connection(('127.0.0.1', args.uart)) as uart, args.uart_log.open('wb', buffering=0) as log, args.capture.open('w', buffering=1) as capture:
        uart.settimeout(1)
        buf = b''
        done = status = False
        deadline = time.monotonic()+120
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
                line = raw.decode(errors='replace').strip()
                if re.fullmatch(r'service replay: count=\d+ phase=\w+ pid=\d+', line):
                    capture.write(line+'\n'+sample()+'\n')
                    uart.sendall(b'\n')
                elif line == 'service replay: done':
                    capture.write(line+'\n')
                    done = True
                elif line.startswith('service replay: FAILED'):
                    raise RuntimeError(line)
                elif line.startswith('init script exit:') and done:
                    if line != 'init script exit: 0':
                        raise RuntimeError('benchmark exit was nonzero')
                    status = True
                    capture.write('service replay: status=0\n')
                elif line == 'pool space: end=bounded_end' and status:
                    capture.write('service teardown: '+sample().removeprefix('service pools: ')+'\n')
                    return
        raise RuntimeError('Takibi capture lacks successful exit and teardown')


if __name__ == '__main__':
    main()
