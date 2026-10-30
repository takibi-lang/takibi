#!/usr/bin/env python3
"""Check physical GEM transfers and masked halt observations on the RPi5."""
import argparse
import hashlib
import json
import os
import re
import statistics
from pathlib import Path
import select
import socket
import subprocess
import sys
import threading
import time

import rpi5_postmortem

ROOT = Path(__file__).resolve().parent.parent
MODES = ('confirmed-ready', 'confirmed-reply', 'unconfirmed-ready', 'unconfirmed-reply',
         'window-closed')
BOARD = bytes.fromhex('020020000002')
PAYLOAD = bytes(range(14, 64))
PASS = b'PASS gem-tx: completion, halt ownership, later sends dropped'
IRQ_PASS = b'PASS gem-probe: complete and masked'
IRQ_MODES = ('irq-primary', 'irq-wrong-enable')
# GitHub issue #787: the after-halt receive needs a frame to land between
# the last RX arm and gem_halt(), a window of about the 14 ms TX deadline.
# Sending every 50 ms left that to chance; every 4 ms puts several frames
# in every such window.
PEER_INTERVAL = 0.004


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
            readable, _, _ = select.select([link, sys.stdin], [], [], PEER_INTERVAL)
            if sys.stdin in readable:
                break
            if link in readable:
                body = link.recv(4096)
                if body[6:12] == BOARD:
                    frames.append({'time': time.time(), 'bytes': body.hex(),
                                   'sha256': hashlib.sha256(body).hexdigest()})
            if time.monotonic() >= next_send:
                link.send(packet)
                next_send = time.monotonic() + PEER_INTERVAL
    print(json.dumps(frames), flush=True)


# GitHub issue #1254: enough frames at the MAC that an untouched buffer cannot
# be a quiet link. The peer sends about 125 during each 500 ms stage.
RX_STAGE_MIN_FRAMES = 10
ETHERTYPE_IN_WORD1 = 0xB588


def validate_inbound_bars(text):
    """Every inbound slot but MSI's and the arena's is disabled, by readback."""
    rows = {int(row[0]): (int(row[1]), int(row[2])) for row in re.findall(
        rb'gem-tx fixture: inbound bar (\d+) lo=(\d+) remap=(\d+)', text)}
    if sorted(rows) != list(range(1, 11)):
        raise RuntimeError('inbound BAR readback incomplete')
    # The two open slots prove the readback reads the registers it names.
    msi_lo, msi_remap = rows[1]
    if msi_lo & 0x1F != 0x1C or not msi_remap & 1:
        raise RuntimeError('MSI inbound BAR differs from its 4 KiB setup')
    arena_lo, arena_remap = rows[2]
    if arena_lo & 0x1F != 3 or not arena_remap & 1 or arena_lo & ~0x1F != arena_remap & ~1:
        raise RuntimeError('arena inbound BAR differs from its 256 KiB setup')
    for bar in range(3, 11):
        lo, remap = rows[bar]
        if lo & 0x1F or remap & 1:
            raise RuntimeError(f'inbound BAR {bar} is not disabled')


def validate_rx_stages(text):
    """A device write lands inside the window and is dropped outside it."""
    stages = {row[0]: {key.decode(): int(value) for key, value in re.findall(rb'(\w+)=(\d+)', row[1])}
              for row in re.findall(rb'gem-tx fixture: rx stage (\w+) (.*)', text)}
    if set(stages) != {b'inside', b'outside'}:
        raise RuntimeError('RX window stages incomplete')
    for stage in stages.values():
        if {'frames', 'own', 'changed', 'word1'} - set(stage):
            raise RuntimeError('RX window stage fields incomplete')
        if stage['frames'] < RX_STAGE_MIN_FRAMES:
            raise RuntimeError('RX window stage saw too few frames at the MAC')
    inside, outside = stages[b'inside'], stages[b'outside']
    if not inside['own'] or not inside['changed'] or (inside['word1'] >> 32) & 0xFFFF != ETHERTYPE_IN_WORD1:
        raise RuntimeError('RX positive control wrote no frame inside the window')
    # Not judged: outside's own bit. GEM sets it even though the buffer write
    # was dropped, and RSR and ISR report nothing, so only the bytes decide.
    if outside['changed']:
        raise RuntimeError('GEM wrote a buffer outside the inbound window')


def validate_xhci_stages(text):
    """GitHub issue #1268: the same window, as xHCI's DMA engine meets it."""
    stages = {row[0]: {key.decode(): int(value) for key, value in re.findall(rb'(\w+)=(\d+)', row[1])}
              for row in re.findall(rb'gem-tx fixture: xhci stage (\w+) (.*)', text)}
    if set(stages) != {b'inside', b'outside', b'moved'}:
        raise RuntimeError('xHCI window stages incomplete')
    for name in (b'inside', b'outside'):
        stage = stages[name]
        if {'cbw', 'data', 'csw', 'changed'} - set(stage):
            raise RuntimeError('xHCI window stage fields incomplete')
        # The transfer ran on both: an idle controller also leaves bytes alone.
        if stage['cbw'] != 1 or not stage['data'] or stage['csw'] != 1:
            raise RuntimeError('xHCI window stage transfer did not run')
    if not stages[b'inside']['changed']:
        raise RuntimeError('xHCI positive control wrote nothing inside the window')
    # Not judged beyond running: the data event reports success for the dropped
    # write, as GEM's ownership bit does, so only the bytes decide.
    if stages[b'outside']['changed']:
        raise RuntimeError('xHCI wrote a buffer outside the inbound window')
    if stages[b'moved'].get('cbw') != 0:
        raise RuntimeError('xHCI completed a transfer through a moved window')


def validate(text, frames, mode):
    marker = f'gem-tx fixture: mode {mode}\n'.encode()
    text = text.replace(b'\r', b'')
    if marker not in text:
        raise RuntimeError('fresh fixture mode marker absent')
    text = text[text.index(marker):]
    if b'FAIL gem-tx:' in text or PASS not in text:
        raise RuntimeError('physical fixture did not pass')
    if b'gem-tx fixture: keep refused at the reserve ok' not in text:
        raise RuntimeError('kept-frame reserve evidence absent (#740)')
    # Three ownership transfers plus four from the #740 keep case: two
    # kept, one refused at the reserve and sent plainly, one resend.
    # GitHub issue #1032 (B'): window-closed moves the inbound window before
    # the seventh, which must then never reach the wire.
    closed = mode == 'window-closed'
    expected = 6 if closed else 7
    if len(frames) != expected:
        raise RuntimeError(f'expected {expected} physical transfers, observed {len(frames)}')
    if closed:
        halt = re.search(rb'gem-tx fixture: halt tsr=(\d+)', text)
        if not halt:
            raise RuntimeError('window-closed halt evidence absent')
        print(f'[kernel/rpi5 gem-tx] window-closed: tsr={int(halt[1]):#x}', flush=True)
        validate_inbound_bars(text)
        validate_rx_stages(text)
        validate_xhci_stages(text)
    for frame in frames:
        body = bytes.fromhex(frame['bytes'])
        if len(body) != 64 or body[6:14] != BOARD + bytes.fromhex('88b5') or body[14:] != PAYLOAD:
            raise RuntimeError('physical frame length or payload checksum mismatch')
    authorities = [line.rsplit(b' ', 1)[1] for line in text.splitlines()
                   if line.startswith(b'gem-tx fixture: authority ')]
    last = b'device' if mode.startswith('unconfirmed') else b'cpu'
    if authorities != [b'cpu', b'cpu', last, last]:
        raise RuntimeError('stored authority sequence differs from halt evidence')


def validate_irq(text, frames, mode):
    text = text.replace(b'\r', b'').decode('ascii', errors='replace')
    marker = f'gem-probe: mode {mode}\n'
    if marker not in text:
        raise RuntimeError('fresh IRQ fixture marker absent')
    text = text[text.index(marker):]
    if 'FAIL gem-probe:' in text or IRQ_PASS.decode() not in text:
        raise RuntimeError('IRQ fixture did not complete successfully')
    if len(frames) != 33:
        raise RuntimeError('IRQ fixture requires 33 genuine checked transfers')
    for frame in frames:
        body = bytes.fromhex(frame['bytes'])
        if len(body) != 64 or body[6:14] != BOARD + bytes.fromhex('88b5') or body[14:] != PAYLOAD:
            raise RuntimeError('IRQ fixture frame length or payload mismatch')
    frequencies = re.findall(r'frequency=(\d+)', text)
    if len(frequencies) != 1 or int(frequencies[0]) <= 0:
        raise RuntimeError('IRQ fixture clock frequency absent or ambiguous')
    frequency = int(frequencies[0])
    rows = [{key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
            for line in text.splitlines() if line.startswith('gem-probe: sample=')]
    keys = {'sample', 'start', 'done', 'wake', 'wakes', 'irq_delta', 'irq_tick'}
    if len(rows) != 32 or any(set(row) != keys for row in rows) or [row['sample'] for row in rows] != list(range(32)):
        raise RuntimeError('IRQ fixture timestamp rows incomplete or reordered')
    for row in rows:
        if row['start'] <= 0 or row['done'] < row['start']:
            raise RuntimeError('IRQ fixture completion timestamp invalid')
        row['elapsed_us'] = (row['done'] - row['start']) * 1000000 / frequency
        if row['irq_delta'] and not row['start'] <= row['irq_tick'] <= row['done']:
            raise RuntimeError('IRQ timestamp lies outside its measured send')
        if row['wakes'] and not row['start'] <= row['wake'] <= row['done']:
            raise RuntimeError('wake timestamp lies outside its measured send')
    median = statistics.median(row['elapsed_us'] for row in rows)
    count = sum(row['irq_delta'] for row in rows)
    if mode == 'irq-primary':
        if count != 32 or median > 200 or max(row['elapsed_us'] for row in rows) > 1000:
            raise RuntimeError('primary bank did not deliver prompt genuine TCOMP interrupts')
    elif mode == 'irq-wrong-enable':
        if count != 0 or median <= 200:
            raise RuntimeError('wrong-bank control did not reproduce missing TCOMP and slow waits')
    else:
        raise RuntimeError('unknown IRQ fixture mode')
    return {'frequency': frequency, 'median_us': median, 'tcomp_irqs': count, 'rows': rows}


def run_case(mode, device, directory, interface):
    import serial
    directory.mkdir(parents=True, exist_ok=True)
    # A previous run's postmortem would read as this run's (#872).
    for stale in ('ddb-postmortem.log', 'swd-snapshot.log'):
        (directory / stale).unlink(missing_ok=True)
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
    irq = mode in IRQ_MODES
    marker = f'{"gem-probe" if irq else "gem-tx fixture"}: mode {mode}\n'.encode()
    pass_marker = IRQ_PASS if irq else PASS
    fail_marker = b'FAIL gem-probe:' if irq else b'FAIL gem-tx:'
    result['control'] = ('primary bank vs wrong additional-queue enable; real completions' if irq else result['control'])
    network = None
    reader = None
    loaded = False
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
                loaded = phase == 'load'
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                text = bytes(transcript).replace(b'\r', b'')
                if mode_time:
                    current = text[text.index(marker):]
                    if fail_marker in current:
                        raise RuntimeError('physical fixture reported failure')
                    if pass_marker in current:
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
        if irq:
            result['irq'] = validate_irq(bytes(transcript), frames, mode)
        else:
            validate(bytes(transcript), frames, mode)
        result['status'] = 'PASS'
        detail = '32 timestamped sends, genuine IRQ bank control' if irq else 'other inbound BARs disabled; no frame and no USED through the moved window; RX and xHCI write inside the window, not outside; xHCI completes nothing through a moved window' if mode == 'window-closed' else 'seven checked transfers (four kept, refused or resent), later sends dropped'
        print(f'PASS kernel/rpi5 gem-tx: {mode}; {detail}', flush=True)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        result['error'] = str(error)
        if loaded:
            # GitHub issue #872: a fixture that fails after the load used to
            # leave only its UART log. Take #869's SWD snapshot and DDB walk
            # while the kernel still runs; the capture thread stops first so
            # the walk reads its own answers. On 2026-10-20 an induced
            # failure got all four cores over SWD but no DDB prompt: the
            # fixture parks core 0 in workload_profile_interrupt_wait during
            # boot, so the snapshot is the evidence and the walk a bonus.
            stop.set()
            reader.join(timeout=1)
            result['postmortem'] = rpi5_postmortem.collect(
                elf, directory, str(error), send_break=lambda: uart.send_break(0.25),
                write=uart.write, read=lambda: uart.read(4096))
            print(f'[kernel/rpi5 gem-tx] {mode}: {result["postmortem"]}', flush=True)
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
    parser.add_argument('--irq', action='store_true')
    args = parser.parse_args()
    if args.peer:
        peer(args.peer)
        return
    device = os.environ.get('RPI5_SERIAL_DEV') or subprocess.check_output(
        ['bash', str(ROOT / 'scripts/rpi5_uart_dev.sh')], text=True).strip()
    default = Path(os.environ.get('TAKIBI_LANE_ARTIFACT_ROOT', ROOT / '_build')) / 'gem-tx-rpi5'
    directory = Path(os.environ.get('KERNEL_GEM_TX_ARTIFACT_DIR', default))
    for mode in IRQ_MODES if args.irq else MODES:
        run_case(mode, device, directory / mode, os.environ.get('ETH_TEST_IFACE', 'enp5s0'))


if __name__ == '__main__':
    main()
