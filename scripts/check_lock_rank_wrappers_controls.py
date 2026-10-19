#!/usr/bin/env python3
"""Controls for check_lock_rank_wrappers.py (#789)."""

from control_patch import replace_once
from check_lock_rank_wrappers import kernel_sources, problems
from pass_line import report_pass

UNRANKED_REGION = '''
private fn unranked_pool_lock() -> RegionPoolGuard(ProcessRecord)[&scheduled_process_pool]
        !{unsafe} {
    let flags: usize = mutex_irq_save();
    return region_pool_lock_saving(&scheduled_process_pool, flags);
}
'''

UNRANKED_MUTEX = '''
fn unranked_mutex_lock(lock: *Mutex @ address) -> SomeGuard[address] {
    let mut guard: SomeGuard[address] = { mutex_acquire(lock) };
    return guard;
}
'''

ONE_LINE = 'private fn unranked_one_line() { region_pool_lock(&p); }\n'


def main() -> int:
    sources = kernel_sources()
    assert not problems(sources), problems(sources)
    path = 'kernel/kernel/process.tkb'
    original = sources[path]
    ranked = 'acquires_lock_40_process_pool, single_instance_lock,'
    assert ranked in original
    controls = {
        # The #745 regression itself: process_pool_lock loses its rank.
        'process pool rank dropped': replace_once(original, ranked, 'single_instance_lock,'),
        'commented rank': replace_once(original, ranked, '// ' + ranked + '\n'),
        'new unranked region wrapper': original + UNRANKED_REGION,
        'new unranked mutex wrapper': original + UNRANKED_MUTEX,
        'one-line body': original + ONE_LINE,
    }
    for name, changed in controls.items():
        assert changed != original, name
        assert problems({**sources, path: changed}), name
    # A rank on a neighbour does not cover an unranked wrapper.
    neighbour = original + UNRANKED_REGION + '''
private fn ranked_neighbour() !{acquires_lock_40_neighbour} { }
'''
    assert problems({**sources, path: neighbour}), 'neighbour rank'
    # Exemptions are reviewed per name, and a stale one is refused.
    assert not problems({**sources, path: original + UNRANKED_REGION},
                        {'unranked_pool_lock': 'control'}), 'exempt'
    assert problems(sources, {'no_such_function': 'stale'}), 'stale exempt'
    # Prose is not code.
    assert not problems({**sources, path: original +
                         '\n// fn x() { region_pool_lock(&p); }\n'}), 'comment'
    report_pass('lock-rank-wrappers controls',
                f'production passes and {len(controls) + 2} unranked or stale shapes fail',
                controls=len(controls) + 2)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
