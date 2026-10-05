#!/usr/bin/env python3
"""Drive workload.c in a disposable FreeBSD guest and query its parked PIDs."""
import argparse
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--known-hosts', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    args = parser.parse_args()
    ssh = ['ssh', '-i', str(args.key), '-o', 'UserKnownHostsFile='+str(args.known_hosts),
           '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-p', str(args.port), 'root@127.0.0.1']
    proc = subprocess.Popen(ssh+['/root/service-replay/service-replay; status=$?; echo "service replay: status=$status"'],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    parent = None
    complete = False
    try:
        with args.capture.open('w', buffering=1) as log:
            for line in proc.stdout:
                log.write(line)
                match = re.fullmatch(r'service replay: count=(\d+) phase=(\w+) pid=(\d+)\n', line)
                if line == 'service replay: status=0\n':
                    complete = True
                if not match:
                    continue
                _, phase, pid = match.groups()
                if phase == 'baseline':
                    parent = pid
                for target in ([parent, pid] if phase == 'inherited' else [pid]):
                    observed = subprocess.run(ssh+['sysctl kern.service_replay='+target+' >/dev/null && dmesg -c'],
                                              capture_output=True, text=True, check=True, timeout=30)
                    samples = [value for value in observed.stdout.splitlines() if value.startswith('service space:')]
                    if len(samples) != 1:
                        raise RuntimeError('observer did not produce exactly one actor sample')
                    log.write(samples[0]+'\n')
                proc.stdin.write('\n')
                proc.stdin.flush()
        if proc.wait(timeout=10) != 0 or not complete:
            raise RuntimeError('FreeBSD capture lacks successful completion: '+proc.stderr.read())
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)


if __name__ == '__main__':
    main()
