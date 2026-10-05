#!/usr/bin/env python3
"""Check the recorded real-kernel retention comparison and its rejection controls."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
from pass_line import CaseCount, report_pass
from measure_service_space import parse_capture

ROOT = Path(__file__).resolve().parents[1]
HERE = ROOT/'kernel/benchmarks/pool_retention'
sys.path.insert(0, str(HERE))
from analyze import parse, summarize


def main():
    paths = sorted((HERE/'captures').glob('*.txt'))
    assert len(paths) == 10
    for platform, total in (('qemu', 4), ('rpi5', 6)):
        selected = [path for path in paths if path.name.startswith(platform+'-')]
        assert len(selected) == total
        assert summarize(selected) == (HERE/f'{platform}.tsv').read_text()
    base = parse_capture((ROOT/'kernel/benchmarks/service_space/captures/takibi-packed.txt').read_text(), 'takibi', 400)
    candidate = parse_capture((HERE/'service/retain0.txt').read_text(), 'takibi', 400)
    lines = ['count\tphase\tretain1_fd_block_bytes\tretain0_fd_block_bytes\tretain1_object_bytes\tretain0_object_bytes']
    for before, after in zip(base, candidate):
        assert before['fd_payload_bytes'] == after['fd_payload_bytes']
        for old, new in zip(before['actors'], after['actors']):
            for key in ('capacity', 'fds', 'regular', 'fd_body', 'fd_dynamic', 'process', 'file_body', 'minrefs', 'maxrefs'):
                assert old[key] == new[key]
        lines.append('\t'.join(map(str, (before['count'], before['phase'], before['pools']['fd_block']['bytes'], after['pools']['fd_block']['bytes'], before['pools']['object']['bytes'], after['pools']['object']['bytes']))))
    assert '\n'.join(lines)+'\n' == (HERE/'service/comparison.tsv').read_text()
    cases = CaseCount()
    for path in paths:
        text = path.read_text()
        first_sample = next(line for line in text.splitlines() if 'count=1 batch=0 ' in line)
        stats = next(line for line in text.splitlines() if 'phase=bounded_end pool=fd_block ' in line)
        bad = [text.replace('retention workload: done\n', ''),
               text.replace('retention workload: status=0', 'retention workload: status=1'),
               text.replace('retention workload: teardown\n', ''),
               text.replace('rounds=16', 'rounds=15', 1),
               text.replace('count=32 batch=0', 'count=31 batch=0', 1),
               text.replace(first_sample, first_sample+'\n'+first_sample, 1),
               text.replace(first_sample, first_sample.split('ns=')[0]+'ns=0', 1),
               text.replace(stats, stats.replace('live=1', 'live=2'), 1),
               text.replace(stats, stats.replace('bytes=', 'unknown='), 1),
               text.replace(stats, stats+' grows=9', 1),
               text.replace(stats, stats.replace('frequency=', 'frequency=-'), 1),
               text.replace(stats, stats.replace('grows=', 'grows=9'), 1),
               text+text]
        for capture in bad:
            cases.note()
            try: parse(capture)
            except ValueError: continue
            raise AssertionError('malformed retention trace accepted: '+path.name)
    cases.note()
    try: summarize(paths)
    except ValueError: pass
    else: raise AssertionError('mixed platform clocks accepted')
    cases.note()
    try: summarize([path for path in paths if 'retain1' in path.name])
    except ValueError: pass
    else: raise AssertionError('missing comparison policy accepted')
    report_pass('pool-retention-controls', f'10 boot traces, 210 batches, and {cases.ran} capture rejection controls', cases=cases.ran)


if __name__ == '__main__':
    main()
