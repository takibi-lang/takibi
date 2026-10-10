#!/usr/bin/env python3
"""Require rejection of CPU access through the real GEM Device authority."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('overlay', type=Path)
    parser.add_argument('compiler', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = args.root.resolve()
    overlay = args.overlay.resolve()
    command = args.compiler
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        parser.error('a compiler command is required')
    subprocess.run([sys.executable, str(root / 'scripts/build_rpi5_gem_tx_fixture.py'),
                    str(root), str(overlay), 'unconfirmed-ready', '--control', 'device-access'], check=True)
    result = subprocess.run(command + ['--emit-struct-layout', 'GemTx'], cwd=overlay,
                            capture_output=True, text=True)
    output = result.stdout + result.stderr
    (overlay / 'device-access.log').write_text(output)
    expected = "dma_cpu_slice for 'GemTx' requires its CPU authority token"
    if result.returncode == 0 or expected not in output:
        raise SystemExit(f'FAIL gem-tx API control: exit={result.returncode}; expected {expected!r}\n{output}')
    print('PASS gem-tx API control: actual Device authority cannot access CPU bytes')


if __name__ == '__main__':
    main()
