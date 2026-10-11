#!/usr/bin/env python3
"""Keep source-check function attribution complete across supported qualifiers.

An inline escape immediately after the declared diagnostic peek used to be
attributed to that peek, and the liveness gate accepted the undeclared escape.
"""

import contextlib
import importlib
import io
import os
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

MATCHERS = {
    'check_liveness_proof_escapes': 'FN_RE',
    'check_address_space_root_mints': 'FN_RE',
    'check_wall_clock_bounds': 'FN_RE',
    'check_platform_file_parity': 'FN_RE',
    'check_stack_proof_states': 'FUNCTION_RE',
    'check_ext2_mutation_guard': 'FUNCTION_RE',
    'check_slot_proof_dropped_to_index': 'FUNCTION_RE',
}


def main():
    cases = CaseCount()
    for module, name in MATCHERS.items():
        checker = importlib.import_module(module)
        matcher = getattr(checker, name)
        function = getattr(checker, 'PEEK', 'control')
        for qualifier in ['', 'private ', 'inline ', 'noinline ',
                          'private inline ', 'private noinline ']:
            assert matcher.match(f'{qualifier}fn {function}() {{}}'), (module, qualifier)
            cases.note()
    import check_liveness_proof_escapes as escape
    previous = Path.cwd()
    with tempfile.TemporaryDirectory(prefix='takibi-escape-controls-') as directory:
        try:
            os.chdir(directory)
            source = Path('kernel/kernel/process.tkb')
            source.parent.mkdir(parents=True)
            # The check also reads the pool libraries (GitHub issue #343);
            # one with only a bound payload accessor keeps that half clean.
            pool = Path('kernel/lib/intrusive_pool.tkb')
            pool.parent.mkdir(parents=True)
            pool.write_text('fn intrusive_pool_ref(T: type, o: borrow O[a]) -> *T @ a {}\n',
                            encoding='ascii')
            baseline = 'fn scalar_snapshot() {}\n'
            for qualifier in ['', 'inline ', 'noinline ', 'private inline ', 'private noinline ']:
                source.write_text(baseline +
                    f'{qualifier}fn unreviewed() {{ intrusive_pool_ref_unproven(live); }}\n',
                    encoding='ascii')
                errors = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errors):
                    status = escape.main()
                assert status != 0, qualifier
                assert 'unreviewed drops a pool liveness proof and is not declared' in errors.getvalue(), errors.getvalue()
                cases.note()
            source.write_text(baseline, encoding='ascii')
            with contextlib.redirect_stdout(io.StringIO()):
                assert escape.main() == 0
            cases.note()
        finally:
            os.chdir(previous)
    report_pass('function-qualifier controls',
                'function attribution includes inline/noinline; undeclared escapes fail by name',
                cases=cases.ran)


if __name__ == '__main__':
    main()
