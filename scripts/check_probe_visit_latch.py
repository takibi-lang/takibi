#!/usr/bin/env python3
"""Contention probes: per-peer arming, and no multi-peer wait on one clock.

GitHub issue #860, two rules over the boot contention probes.

1. Visit latch. Every core's idle loop (kernel/arch/arm64/kernel/secondary.tkb,
   kernel_idle_loop) asks each probe `<name>_is_armed(core_id)` and enters its
   run function when it says yes. A peer that has already done what the
   arming asks must hear "no": GitHub issue #853 was a peer that kept
   re-entering the armed occupancy probe after its visit, and under the 651
   race window every entry sits 0.75 s with interrupts masked, so core 0's
   next world stop found it masked. So every arming question takes the
   calling core and reads that core's own progress -- a PeerTally count, a
   per-core word, or the turn it names. A probe whose run function does not
   return while it is armed cannot be re-entered while armed; those few are
   listed in HOLDS with the reason, and still take the core.

2. One clock per peer. `peer_tick_window_peer()` is the fixed core 0 / CPU 1
   pair's window: on core 0 it is CPU 1's ticks. A core-0 wait on a count
   that several peers add to, bounded by that one clock, times the whole
   count out while CPU 1 ticks and a later peer is still masked -- the
   aggregate entry-count shape GitHub issue #756 removed from the probes
   routed through kernel/lib/peer_round.tkb, and #860 found again in the log
   storm. A wait across several peers takes each peer's own window in turn
   (peer_round.tkb's waits, or a `for cpu` loop over
   peer_tick_window_policy(cpu, ...)). The function that may still call
   peer_tick_window_peer() is listed in PAIR_WINDOW with why one clock is
   the right one there, so a new use is a reviewed decision.

Source-level only: rule 1 sees that the question reads the core's own
progress, not that it reads the right word; rule 2 sees the call, not the
predicate it bounds.
"""

import re
import sys
from pathlib import Path

from check_model_function_map import function_body, masked_sources
from pass_line import report_pass

IDLE = 'kernel/arch/arm64/kernel/secondary.tkb'
CALL = re.compile(r'\b(\w+_is_armed)\s*\(((?:[^()]|\([^()]*\))*)\)')
# A read of the calling core's own progress.
OWN = re.compile(r'peer_tally_count\s*\([^,]+,\s*cpu\s*\)'
                 r'|\[\s*(own|core)\s*\]|==\s*cpu\b')

HOLDS = {
    'signal_contention_is_armed':
        'run function loops while armed; returns only once disarmed',
    'pool_walk_contention_is_armed':
        'run function loops while armed; returns only once disarmed',
}

PAIR_WINDOW = {
    'ext2_mutation_probe_reader': 'a peer waits on core 0',
    'ext2_mutation_probe_mutator': 'a peer waits on core 0',
    'ext2_mutation_probe_core0_reader':
        'core 0 waits for the FIRST peer to try, and CPU 1 is one of the '
        'contenders, so its ticks bound an idle contender',
    'pool_walk_once': 'a peer waits on core 0',
    'console_probe_wait': 'a peer waits on core 0',
    'log_storm_wait_word': 'a secondary waits on core 0',
}
DEFINITION = re.compile(r'^(?:private\s+)?(?:inline\s+|noinline\s+)?fn\s+(\w+)\s*\(', re.M)


def sources():
    paths = sorted(Path('kernel/kernel').glob('*.tkb'))
    paths += sorted(Path('kernel/lib').glob('*.tkb'))
    paths.append(Path(IDLE))
    return {str(path): path.read_text(encoding='ascii') for path in paths}


def armed_errors(tree):
    errors, held = [], set()
    idle = function_body('kernel_idle_loop', tree.get(IDLE, ''))
    if idle is None:
        return [f'{IDLE}: cannot find kernel_idle_loop'], 0
    calls = CALL.findall(masked_sources(idle))
    if not calls:
        errors.append(f'{IDLE}: kernel_idle_loop asks no probe whether it is armed')
    for name, argument in calls:
        if argument.strip() != 'core_id':
            errors.append(f'{IDLE}: {name}({argument.strip()}) must be asked '
                          'for this core: pass core_id (GitHub issue #860)')
        body = None
        for path, source in tree.items():
            if re.search(rf'\bfn\s+{name}\s*\(', masked_sources(source)):
                body = function_body(name, source)
                break
        if body is None:
            errors.append(f'{name}: definition not found')
            continue
        if name in HOLDS:
            held.add(name)
            continue
        if not OWN.search(masked_sources(body)):
            errors.append(f'{name}: armed for every peer alike; also read the '
                          'calling core\'s own progress (its visit latch), so a '
                          'peer that has done its part stays idle (GitHub '
                          'issues #853, #860)')
    for name in HOLDS:
        if name not in held:
            errors.append(f'{name}: listed in HOLDS but not asked by the idle loop')
    return errors, len(calls)


def window_errors(tree):
    errors, seen = [], set()
    for path, source in tree.items():
        if path.endswith('/peer_tick_window.tkb'):
            continue
        masked = masked_sources(source)
        if 'peer_tick_window_peer' not in masked:
            continue
        for name in DEFINITION.findall(masked):
            body = function_body(name, source)
            if body is None or not re.search(r'\bpeer_tick_window_peer\s*\(',
                                             masked_sources(body)):
                continue
            if name in PAIR_WINDOW:
                seen.add(name)
                continue
            errors.append(f'{path}: {name}: waits on peer_tick_window_peer(), '
                          'one fixed peer\'s clock; a wait across several peers '
                          'takes each peer\'s own window (kernel/lib/'
                          'peer_round.tkb; GitHub issues #756, #860)')
    for name in PAIR_WINDOW:
        if name not in seen:
            errors.append(f'{name}: listed in PAIR_WINDOW but no longer calls '
                          'peer_tick_window_peer(); drop the entry')
    return errors, len(seen)


def main(tree=None):
    tree = sources() if tree is None else tree
    errors, asked = armed_errors(tree)
    more, pairs = window_errors(tree)
    errors += more
    if errors:
        for error in errors:
            print(f'ERROR probe-visit-latch: {error}')
        return 1
    report_pass('probe-visit-latch',
                'every idle-loop arming question reads the calling core\'s own '
                'progress; fixed-pair windows only where reviewed',
                asked=asked, holds=len(HOLDS), pair_windows=pairs)
    return 0


if __name__ == '__main__':
    sys.exit(main())
