#!/usr/bin/env python3
"""Exercise aggregate await recording and its real CLI without clocks or boards."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

from await_timing import AwaitTiming
from pass_line import CaseCount, report_pass

CASES = CaseCount()

ROOT = Path(__file__).resolve().parent.parent


def summarize(directory):
    CASES.note()
    return subprocess.run([sys.executable, str(ROOT / 'scripts/summarize_await_timing.py'),
                           str(directory)], capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        aggregate = root / 'aggregate'
        aggregate.mkdir()
        with patch.dict(os.environ, {'TAKIBI_AWAIT_TIMING_DIR': str(aggregate), 'TAKIBI_AWAIT_TIMING_LANE': 'test-lane'}):
            with contextlib.redirect_stdout(io.StringIO()):
                first = AwaitTiming(str(root / 'uart.jsonl'), 100, 10, [b'ready'], [],
                                    label='driver A', connection=False)
                first.record('await-line 1', True, 105)
                first.record('console prompt 1', True, 106)
                first.finish(110)
                second = AwaitTiming(str(root / 'uart.jsonl'), 200, 20, [b'ready'], [],
                                     label='driver B', origin='postmortem', connection=False)
                second.record('await-line 1', True, 215)
                second.finish(220)
        result = summarize(aggregate)
        assert result.returncode == 0, result.stderr
        assert '2 captures, 3 arrivals, 2 over half budget, 1 not arrived' in result.stdout
        assert 'driver A [driver start]: 6.000s/10.000s (60.0%)' in result.stdout
        assert 'driver B [postmortem]: 15.000s/20.000s (75.0%)' in result.stdout
        assert 'not arrived: console prompt 1' in result.stdout
        # Reusing the local artifact must not overwrite another capture's
        # aggregate observations. Standalone runs must not join an aggregate.
        assert len(list(aggregate.glob('*.jsonl'))) == 2
        with patch.dict(os.environ, {'TAKIBI_AWAIT_TIMING_DIR': str(aggregate)}, clear=True), contextlib.redirect_stdout(io.StringIO()):
            standalone = AwaitTiming(None, 0, 10, [], [], connection=False)
            standalone.finish(10)
        assert len(list(aggregate.glob('*.jsonl'))) == 2
        # An unavailable local artifact still permits aggregate observations.
        with patch.dict(os.environ, {'TAKIBI_AWAIT_TIMING_DIR': str(aggregate), 'TAKIBI_AWAIT_TIMING_LANE': 'test-lane'}):
            with contextlib.redirect_stdout(io.StringIO()):
                unavailable = AwaitTiming(str(root / 'absent/uart.jsonl'), 0, 10, [], [],
                                          connection=False)
                unavailable.finish(10)
        assert summarize(aggregate).returncode == 0
        # Run the actual wrapper, so exporting the lane is verified through
        # the same process boundary as the maintained aggregate.
        CASES.note()
        parent_receipts = root / 'parent-lane-timing'
        parent_receipts.mkdir()
        env = dict(os.environ, TAKIBI_AWAIT_TIMING_DIR=str(aggregate),
                   TAKIBI_LANE_TIMING_DIR=str(parent_receipts))
        # A simulated lane must never append to the parent aggregate's real
        # duration receipts, even when langcheck runs inside allcheck.
        env.pop('TAKIBI_LANE_TIMING_DIR', None)
        program = ("import sys; sys.path.insert(0, sys.argv[1]); "
                   "from await_timing import AwaitTiming; "
                   "t=AwaitTiming(None, 0, 10, [], [], connection=False); t.finish(10)")
        wrapper = subprocess.run(['bash', str(ROOT / 'scripts/run_lane.sh'),
                                  'control-lane', sys.executable, '-c', program,
                                  str(ROOT / 'scripts')], env=env, capture_output=True, text=True)
        assert wrapper.returncode == 0, wrapper.stderr
        assert not list(parent_receipts.iterdir()), 'control polluted parent lane receipts'
        assert 'control-lane: kernel/oops' in summarize(aggregate).stdout
        empty = root / 'empty'
        empty.mkdir()
        result = summarize(empty)
        assert result.returncode == 0 and '0 captures, 0 arrivals' in result.stdout
        (empty / 'broken.jsonl').write_text('{broken\n')
        result = summarize(empty)
        assert result.returncode != 0 and 'await summary unavailable' in result.stdout
        (empty / 'broken.jsonl').write_text(json.dumps({'status': 'unknown'}) + '\n')
        result = summarize(empty)
        assert result.returncode != 0 and 'unknown arrival status' in result.stdout
    makefile = (ROOT / 'Makefile').read_text()
    for target in ('allcheck:', 'cicheck:'):
        CASES.note()
        recipe = makefile.split('\n' + target + '\n', 1)[1].split('\n\n', 1)[0]
        assert 'rm -rf "$(AWAIT_TIMING_DIR)"' in recipe
        assert 'export TAKIBI_AWAIT_TIMING_DIR="$(AWAIT_TIMING_DIR)"' in recipe
        assert 'summarize_await_timing.py "$(AWAIT_TIMING_DIR)" || true' in recipe
        assert recipe.index('summarize_await_timing.py') < recipe.index('if [ $$status')
    assert 'export TAKIBI_AWAIT_TIMING_LANE="$lane"' in (ROOT / 'scripts/run_lane.sh').read_text()
    report_pass('await-summary controls', 'independent captures and phase budgets, half-budget '
                'boundaries, missing arrivals and artifacts, invalid input and aggregate wiring hold', cases=CASES.ran)
    return 0


if __name__ == '__main__':
    sys.exit(main())
