#!/usr/bin/env python3
"""Validate the dated FD/fork evidence and reject broken capture contracts."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
from measure_service_space import parse_capture, render_tsv
from pass_line import CaseCount, report_pass


def main():
    root = Path(__file__).resolve().parent.parent / 'kernel/benchmarks/service_space'
    texts = {os: (root/'captures'/f'{os}.txt').read_text() for os in ('takibi', 'linux', 'freebsd')}
    samples = {os: parse_capture(text, os) for os, text in texts.items()}
    assert render_tsv(samples) == (root/'comparison.tsv').read_text()
    for os, first in samples.items():
        second = parse_capture((root/'captures'/f'{os}-repeat.txt').read_text(), os)
        # PIDs, addresses and identity fingerprints may change on a new run.
        assert render_tsv({os: first}) == render_tsv({os: second})
        for a, b in zip(first, second):
            for x, y in zip(a['actors'], b['actors']):
                for key in ('capacity', 'fds', 'regular', 'fd_body', 'fd_dynamic', 'process', 'file_body', 'minrefs', 'maxrefs'):
                    assert x[key] == y[key]
            if os == 'takibi':
                assert a['pools'] == b['pools']
    packed_texts = [(root/'captures'/name).read_text() for name in ('takibi-packed.txt', 'takibi-packed-repeat.txt')]
    packed = [parse_capture(text, 'takibi', 400) for text in packed_texts]
    assert render_tsv({'takibi': packed[0]}) == (root/'packed.tsv').read_text()
    assert render_tsv({'takibi': packed[0]}) == render_tsv({'takibi': packed[1]})
    for before, after, repeat in zip(samples['takibi'], packed[0], packed[1]):
        for old, new, again in zip(before['actors'], after['actors'], repeat['actors']):
            for key in ('capacity', 'fds', 'regular', 'fd_body', 'process', 'file_body', 'minrefs', 'maxrefs'):
                assert old[key] == new[key] == again[key]
            assert new['fd_dynamic'] == again['fd_dynamic'] == old['fd_dynamic']//528*400
        assert before['pools']['fd_block']['live'] == after['pools']['fd_block']['live']
        assert after['pools'] == repeat['pools']
        for name in before['pools']:
            if name != 'fd_block':
                assert before['pools'][name] == after['pools'][name]
    for text, size in ((packed_texts[0], 528), (texts['takibi'], 400)):
        try:
            parse_capture(text, 'takibi', size)
        except ValueError:
            pass
        else:
            raise AssertionError('capture accepted with the wrong FD layout')
    controls = []
    for os, text in texts.items():
        controls += [(os, '\n'.join(text.splitlines()[1:])),
                     (os, text.replace('service replay: done\n', '')),
                     (os, text.replace('service replay: status=0', 'service replay: status=1')),
                     (os, text.replace('phase=opened', 'phase=closed', 1)),
                     (os, text+text),
                     (os, text.replace('count=32', 'count=31', 1))]
    for os in ('linux', 'freebsd'):
        text = texts[os]
        for old, new in (('fds=35', 'fds=34'), ('regular=32', 'regular=31'),
                         ('minrefs=2', 'minrefs=1'), ('maxrefs=2', 'maxrefs=3'),
                         ('process=', 'unknown='), ('file_body=', 'file_body=-'),
                         ('service space:', 'missing observation:')):
            controls.append((os, text.replace(old, new, 1)))
        child = samples[os][2]['actors'][1]
        line = next(value for value in text.splitlines() if value.startswith(f"service space: pid={child['pid']} "))
        controls.append((os, text.replace(line, line.replace(f"hash={child['hash']}", 'hash=0'), 1)))
    text = texts['takibi']
    for old, new in (('"capacity": 16', '"capacity": 1'), ('"live": 33', '"live": 34'),
                     ('"live": 7', '"live": 6'), ('"minrefs": 2', '"minrefs": 1'),
                     ('"bytes": 8192', '"bytes": 4096')):
        controls.append(('takibi', text.replace(old, new, 1)))
    controls.append(('takibi', '\n'.join(text.splitlines()[:-1])))
    controls.append(('freebsd', texts['freebsd'].replace('threads=1', 'threads=2', 1)))
    controls.append(('freebsd', texts['freebsd'].replace('retired=0', 'retired=1', 1)))
    cases = CaseCount()
    for os, bad in controls:
        cases.note()
        try:
            parse_capture(bad, os)
        except (ValueError, KeyError, TypeError):
            continue
        raise AssertionError('invalid service capture accepted: '+os)
    report_pass('service-space-controls', f'80 phase windows, 96 actors including baseline and packed repeats, and {cases.ran} capture rejection controls', cases=cases.ran)


if __name__ == '__main__':
    main()
