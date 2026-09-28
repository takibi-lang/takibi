#!/usr/bin/env python3
"""Request a terminal system stop from an already-running interactive ash."""

import argparse
import time

import serial


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--command', choices=('halt', 'poweroff', 'reboot'),
                        default='poweroff')
    args = parser.parse_args()
    name = 'restart' if args.command == 'reboot' else args.command
    marker = f'\nsystem stop: {name} (all cores parked)\n'.encode('ascii')
    captured = bytearray()
    with serial.serial_for_url(args.port, baudrate=115200, timeout=0.1) as uart:
        with open(args.log, 'wb') as log:
            uart.write(f'x=; /bin/busybox {args.command} -f\n'.encode('ascii'))
            uart.flush()
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                data = uart.read(4096)
                if data:
                    log.write(data)
                    log.flush()
                    captured.extend(data)
                    if marker in bytes(captured).replace(b'\r', b''):
                        print(f'PASS system stop: {name} (all cores parked)')
                        return
    raise SystemExit(f'FAIL system stop: {name}: expected marker missing; log: {args.log}')


if __name__ == '__main__':
    main()
