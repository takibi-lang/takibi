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

# GitHub issue #966: an unmasked wrapper without may_block, and a saving
# wrapper that saves no mask.
UNMASKED_NO_MAY_BLOCK = '''
private fn unmasked_pool_lock() -> RegionPoolGuard(ProcessRecord)[&scheduled_process_pool]
        !{unsafe, acquires_lock_40_unmasked_pool} {
    return region_pool_lock(&scheduled_process_pool);
}
'''

SAVING_ZERO = '''
private fn saving_zero_pool_lock() -> RegionPoolGuard(ProcessRecord)[&scheduled_process_pool]
        !{unsafe, acquires_lock_40_saving_zero_pool, may_block} {
    return region_pool_lock_saving(&scheduled_process_pool, 0);
}
'''

UNMASKED_HIGH_RANK = '''
private fn unmasked_high_pool_lock() -> RegionPoolGuard(ProcessRecord)[&scheduled_process_pool]
        !{unsafe, acquires_lock_40_unmasked_pool, may_block, lock_guard_40_unmasked_pool} {
    return region_pool_lock(&scheduled_process_pool);
}
'''

MASKED_LOW_RANK = '''
private fn masked_low_pool_lock() -> RegionPoolGuard(ProcessRecord)[&scheduled_process_pool]
        !{unsafe, acquires_lock_39_masked_pool, lock_guard_39_masked_pool} {
    let flags: usize = mutex_irq_save();
    return region_pool_lock_saving(&scheduled_process_pool, flags);
}
'''

# GitHub issue #1350: an unmasked lock or release that leaves the count alone.
UNRAISED_TAKE = '''
private fn unraised_pool_lock() -> RegionPoolGuard(ProcessRecord)[&scheduled_process_pool]
        !{unsafe, acquires_lock_39_unraised_pool, may_block, lock_guard_39_unraised_pool} {
    return region_pool_lock(&scheduled_process_pool);
}
'''

UNLOWERED_GIVE = '''
private fn unlowered_pool_unlock(guard: sink RegionPoolGuard(ProcessRecord)[&scheduled_process_pool]) {
    region_pool_unlock(guard);
}
'''

UNRAISED_FIELD = '''
private fn unraised_field_take() -> GuardedFieldGuard[&some_lock]
        !{may_block, acquires_lock_38_guarded_field, lock_guard_38_guarded_field} {
    return guarded_field_take(&some_lock);
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
    # GitHub issue #1332: an added shape goes in a file of its own, so only
    # that snippet is scanned again rather than all of process.tkb per
    # control. The scan is per file, so the verdict is the same.
    added = 'kernel/kernel/lock_rank_control.tkb'
    assert added not in sources
    edits = {
    }
    controls = {
        # The #745 regression itself: process_pool_lock loses its rank.
        'process pool rank dropped': replace_once(original, ranked, 'single_instance_lock,'),
        'commented rank': replace_once(original, ranked, '// ' + ranked + '\n'),
        'new unranked region wrapper': UNRANKED_REGION,
        'new unranked mutex wrapper': UNRANKED_MUTEX,
        'one-line body': ONE_LINE,
        'unmasked wrapper without may_block': UNMASKED_NO_MAY_BLOCK,
        'saving wrapper that saves no mask': SAVING_ZERO,
        'unmasked lock in the masking band': UNMASKED_HIGH_RANK,
        'masking lock in the unmasked band': MASKED_LOW_RANK,
        'unmasked lock without the raise': UNRAISED_TAKE,
        'unmasked release without the lower': UNLOWERED_GIVE,
        'field lock without the raise': UNRAISED_FIELD,
    }
    for name, changed in edits.items():
        assert changed != original, name
        assert problems({**sources, path: changed}), name
    for name, shape in controls.items():
        assert problems({**sources, added: shape}), name
    # A rank on a neighbour does not cover an unranked wrapper.
    neighbour = UNRANKED_REGION + '''
private fn ranked_neighbour() !{acquires_lock_40_neighbour} { }
'''
    assert problems({**sources, added: neighbour}), 'neighbour rank'
    # The accepted unmasked shape (#966).
    assert not problems({**sources, added: UNMASKED_NO_MAY_BLOCK.replace(
        'acquires_lock_40_unmasked_pool}', 'acquires_lock_39_unmasked_pool, may_block}'
    ).replace('return region_pool_lock', 'preempt_lock_raise(); return region_pool_lock')}), \
        'unmasked ok'
    # Exemptions are reviewed per name, and a stale one is refused.
    assert not problems({**sources, added: UNRANKED_REGION},
                        {'unranked_pool_lock': 'control'}), 'exempt'
    assert problems(sources, {'no_such_function': 'stale'}), 'stale exempt'
    # Prose is not code.
    assert not problems({**sources, added:
                         '\n// fn x() { region_pool_lock(&p); }\n'}), 'comment'
    report_pass('lock-rank-wrappers controls',
                f'production passes and {len(edits) + len(controls) + 2} unranked or stale shapes fail',
                controls=len(edits) + len(controls) + 2)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
