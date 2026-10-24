#!/usr/bin/env python3
"""A rule about how this kernel's locks may be used.

It comes from defects made on 2026-08-30, in the same session that added
five locks to remove races.

RULE 1 -- a GLOBAL Mutex must not be passed to mutex_init.

    It needs no initialisation: .bss is zeroed by both entry paths and a
    zeroed word is SPIN_LOCK_FREE, which kernel/lib/mutex.tkb asserts.
    Calling mutex_init on one is worse than redundant, because mutex_init
    FORCE-FREES -- on two cores it releases a lock another core is
    holding. Two ways that went wrong in one session:

      - a lazy `if (ready == false) { ready = true; mutex_init(&lock); }`,
        which sets the flag BEFORE the init, so a second core can acquire
        a mutex the first has not written yet. Double-checked locking
        without the atomics, in the function whose purpose was to remove a
        race.
      - unified_fd_table_init, which is called repeatedly and re-freed the
        refcount lock on every call.

    mutex_init is for a Mutex embedded in storage that is RECYCLED, where
    zero-initialisation is not what the caller has. IntrusivePool's
    per-pool lock is the real caller.

RULE 2 (raw atomic intrinsics need a reviewed file) retired with GitHub
issue #989 (#567 Stage 3): the compiler counts a raw atomic intrinsic call
as a raw site under --confine-raw-authority, so kernel/RAW_MINT_FILES is
now the one list of files that may call one.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

KERNEL = pathlib.Path("kernel")

GLOBAL_RE = re.compile(r"^(?:private )?let mut ([A-Za-z_0-9]+)\s*:", re.M)
MUTEX_INIT_RE = re.compile(r"mutex_init\(&([A-Za-z_0-9]+)")


def main():
    if not KERNEL.is_dir():
        print("FAIL lock-discipline: kernel/ not found", file=sys.stderr)
        return 1

    failures = []
    checked_files = 0
    global_inits = 0

    for path in sorted(KERNEL.rglob("*.tkb")):
        text = path.read_text()
        rel = str(path.relative_to(KERNEL))
        checked_files += 1

        # RULE 1
        globals_here = set(GLOBAL_RE.findall(text))
        for name in MUTEX_INIT_RE.findall(text):
            if name in globals_here:
                global_inits += 1
                failures.append(
                    "%s calls mutex_init on the global '%s'. A global Mutex "
                    "is already free -- .bss is zeroed and a zeroed word is "
                    "SPIN_LOCK_FREE -- and mutex_init FORCE-FREES, so on two "
                    "cores this can release a lock another core holds. "
                    "Delete the call; see kernel/lib/mutex.tkb" % (rel, name))

    if failures:
        for f in failures:
            print("FAIL lock-discipline: %s" % f, file=sys.stderr)
        return 1

    report_pass("lock-discipline",
                "%d files checked; no global Mutex is initialised"
                % checked_files,
                files=checked_files)
    return 0


if __name__ == "__main__":
    sys.exit(main())
