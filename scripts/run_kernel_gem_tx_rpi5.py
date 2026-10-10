#!/usr/bin/env python3
"""Check physical GEM transfers and masked halt observations on the RPi5."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
MODES = ('confirmed-ready', 'confirmed-reply', 'unconfirmed-ready', 'unconfirmed-reply')
BOARD = bytes.fromhex('020020000002')
PAYLOAD = bytes(range(14, 64))
PASS = b'PASS gem-tx: completion, halt ownership, later sends dropped'


def peer(interface):
    # EOF from the lease-owning parent also stops this privileged peer.
    host = bytes.fromhex(Path('/sys/class/net', interface, 'address').read_text().strip().replace(':', ''))
    packet = BOARD + host + bytes.fromhex('88b5') + PAYLOAD
    frames = []
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B5)) as link:
        link.bind((interface, 0))
        link.setblocking(False)
        print('READY', flush=True)
        next_send = 0.0
        while True:
            readable, _, _ = select.select([link, sys.stdin], [], [], 0.05)
            if sys.stdin in readable:
                break
            if link in readable:
                body = link.recv(4096)
                if body[6:12] == BOARD:
                    frames.append({'time': time.time(), 'bytes': body.hex(),
                                   'sha256': hashlib.sha256(body).hexdigest()})
            if time.monotonic() >= next_send:
                link.send(packet)
                next_send = time.monotonic() + 0.05
    print(json.dumps(frames), flush=True)


def validate(text, frames, mode):
    marker = f'gem-tx fixture: mode {mode}\n'.encode()
    text = text.replace(b'\r', b'')
    if marker not in text:
        raise RuntimeError('fresh fixture mode marker absent')
    text = text[text.index(marker):]
    if b'FAIL gem-tx:' in text or PASS not in text:
        raise RuntimeError('physical fixture did not pass')
    if len(frames) != 3:
        raise RuntimeError(f'expected three physical transfers, observed {len(frames)}')
    for frame in frames:
        body = bytes.fromhex(frame['bytes'])
        if len(body) != 64 or body[6:14] != BOARD + bytes.fromhex('88b5') or body[14:] != PAYLOAD:
            raise RuntimeError('physical frame length or payload checksum mismatch')
    authorities = [line.rsplit(b' ', 1)[1] for line in text.splitlines()
                   if line.startswith(b'gem-tx fixture: authority ')]
    last = b'device' if mode.startswith('unconfirmed') else b'cpu'
    if authorities != [b'cpu', b'cpu', last, last]:
        raise RuntimeError('stored authority sequence differs from halt evidence')


def run_case(mode, device, directory, interface):
    import serial
    directory.mkdir(parents=True, exist_ok=True)
    source_elf = ROOT / f'kernel/build/rpi5/kernel-gem-tx-fixture-{mode}.elf'
    elf = directory.resolve() / 'kernel.elf'
    elf.write_bytes(source_elf.read_bytes())
    result = {'mode': mode, 'status': 'FAIL', 'elf_sha256': hashlib.sha256(elf.read_bytes()).hexdigest(),
              'control': 'real USED hidden; real TGO hidden only in unconfirmed modes'}
    transcript = bytearray()
    stop = threading.Event()
    mode_time = []
    load_started = None
    capture_lock = threading.Lock()
    marker = f'gem-tx fixture: mode {mode}\n'.encode()
    network = None
    reader = None
    started = time.monotonic()
    uart = serial.Serial(device, 115200, timeout=0.1)
    try:
        uart.reset_input_buffer()

        def capture():
            while not stop.is_set():
                data = uart.read(4096)
                with capture_lock:
                    transcript.extend(data)
                    if data:
                        (directory / 'uart.log').write_bytes(transcript)
                    if not mode_time and marker in bytes(transcript).replace(b'\r', b''):
                        mode_time.append(time.time())

        reader = threading.Thread(target=capture, daemon=True)
        reader.start()
        with (directory / 'peer.stderr').open('w') as error:
            network = subprocess.Popen(['sudo', '-n', 'python3', str(Path(__file__).resolve()),
                                        '--peer', interface], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=error, text=True)
            readable, _, _ = select.select([network.stdout], [], [], 5)
            if not readable or network.stdout.readline().strip() != 'READY':
                raise RuntimeError('Ethernet peer did not become ready')
            for phase, command in (
                ('reset', ['bash', 'scripts/rpi5_jtag_reset.sh', '--resident-image-unchanged']),
                    ('load', ['bash', 'scripts/rpi5_jtag_load.sh', str(elf)])):
                if phase == 'load':
                    # A warm reset may replay its resident image. Only the
                    # subsequent SWD-loaded image can earn this verdict.
                    with capture_lock:
                        transcript.clear()
                        mode_time.clear()
                        uart.reset_input_buffer()
                    load_started = time.time()
                    result['load_started'] = load_started
                print(f'[kernel/rpi5 gem-tx] {mode}: {phase}', flush=True)
                with (directory / f'{phase}.log').open('w') as output:
                    subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                text = bytes(transcript).replace(b'\r', b'')
                if mode_time:
                    current = text[text.index(marker):]
                    if b'FAIL gem-tx:' in current:
                        raise RuntimeError('physical fixture reported failure')
                    if PASS in current:
                        break
                if network.poll() is not None:
                    raise RuntimeError('Ethernet peer exited during fixture')
                time.sleep(0.1)
            else:
                raise RuntimeError('fresh fixture completion absent after 180s')
            network.stdin.close()
            network.wait(timeout=5)
            if network.returncode:
                raise RuntimeError('Ethernet peer failed')
            frames = json.loads(network.stdout.read())
        (directory / 'ethernet-all.json').write_text(json.dumps(frames, indent=2) + '\n')
        result['mode_observed'] = mode_time[0]
        frames = [frame for frame in frames if frame['time'] >= load_started]
        (directory / 'ethernet.json').write_text(json.dumps(frames, indent=2) + '\n')
        validate(bytes(transcript), frames, mode)
        result['status'] = 'PASS'
        print(f'PASS kernel/rpi5 gem-tx: {mode}; three checked transfers, later sends dropped', flush=True)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        result['error'] = str(error)
        raise
    finally:
        if network is not None and network.poll() is None:
            if not network.stdin.closed:
                network.stdin.close()
            network.wait(timeout=5)
        if network is not None:
            remaining = network.stdout.read()
            if remaining.strip():
                (directory / 'ethernet-all.json').write_text(remaining)
        stop.set()
        if reader:
            reader.join(timeout=1)
        uart.close()
        (directory / 'uart.log').write_bytes(transcript)
        result['elapsed_seconds'] = time.monotonic() - started
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer')
    args = parser.parse_args()
    if args.peer:
        peer(args.peer)
        return
    device = os.environ.get('RPI5_SERIAL_DEV') or subprocess.check_output(
        ['bash', str(ROOT / 'scripts/rpi5_uart_dev.sh')], text=True).strip()
    default = Path(os.environ.get('TAKIBI_LANE_ARTIFACT_ROOT', ROOT / '_build')) / 'gem-tx-rpi5'
    directory = Path(os.environ.get('KERNEL_GEM_TX_ARTIFACT_DIR', default))
    for mode in MODES:
        run_case(mode, device, directory / mode, os.environ.get('ETH_TEST_IFACE', 'enp5s0'))


if __name__ == '__main__':
    main()
