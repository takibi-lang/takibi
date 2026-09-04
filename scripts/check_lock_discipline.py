#!/usr/bin/env python3
"""Two rules about how this kernel's locks and atomics may be used.

Both come from defects made on 2026-08-30, in the same session that added
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

RULE 2 -- the raw atomic intrinsics have an allowlist.

    They are `unsafe`-gated already, and SPEC.md says ordinary code should
    reach them through the lock or through issue #299's publication
    record. That is a sentence; this is the check. What it buys is not
    prevention but REVIEW: adding a file here is a claim that this
    particular use needs the raw instruction.

    The compiler now gives every raw atomic a `requires_mmu` effect, so an
    atomic reachable from an `!{mmu_off}` function is a build error. The
    allowlist remains a separate source-level policy: ordinary code should
    use the reviewed lock or publication abstraction even after the MMU is
    active, rather than spreading unchecked ordering arguments through the
    kernel.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

KERNEL = pathlib.Path("kernel")

GLOBAL_RE = re.compile(r"^(?:private )?let mut ([A-Za-z_0-9]+)\s*:", re.M)
MUTEX_INIT_RE = re.compile(r"mutex_init\(&([A-Za-z_0-9]+)")
ATOMIC_RE = re.compile(
    r"\batomic_(?:load_acquire|store_release|swap_acquire|fetch_add_relaxed)\b")

# Files permitted to use the raw atomic intrinsics, and why.
ATOMIC_ALLOWED = {
    "lib/spinlock.tkb":
        "the lock itself; every other user is supposed to go through it",
    "lib/diagnostic_ring.tkb":
        "GitHub issue #299's publication protocol, which is the other safe "
        "surface over the atomics",
    "arch/arm64/kernel/secondary.tkb":
        "the secondary core's tick counter, genuinely written by one core "
        "and read by another with no lock between them",
    "arch/arm64/kernel/exception_evidence.tkb":
        "GitHub issue #496: DdbSnapshot's one valid-last word. The snapshot "
        "is captured with interrupts masked and has no competing writer; "
        "release ordering prevents an external debugger from accepting its "
        "fields before the completed sequence is published. A lock cannot "
        "help a halted out-of-band reader",
    "kernel/fd_table.tkb":
        "the shared-object contention probe lives in this file, because the "
        "retain/release it exercises are private to it",
    "kernel/pool_contention_evidence.tkb": "two-core contention probe",
    "kernel/freelist_contention_evidence.tkb": "two-core contention probe",
    "kernel/page_contention_evidence.tkb": "two-core contention probe",
    "kernel/asid_contention_evidence.tkb": "two-core contention probe",
    "kernel/pid_contention_evidence.tkb": "two-core contention probe",
    "kernel/tag_contention_evidence.tkb": "two-core contention probe",
    "kernel/schedule_contention_evidence.tkb": "two-core contention probe",
    "lib/occupancy.tkb":
        "GitHub issue #479: \"no other core is inside this region\" as a "
        "linear value. Each core writes ONLY its own word, so there is no "
        "read-modify-write and nothing to exclude -- the atomics carry the "
        "ORDERING, which is the whole content of the claim. A lock would be "
        "the wrong answer here for the reason it is wrong in printk and in "
        "a crash reporter: this runs while something is being torn down, "
        "and it cannot block on the thing tearing it down. Not boot "
        "reachable, so issue #484's mmu_off hazard does not apply",
    "kernel/process.tkb":
        "GitHub issue #479 Group B: the crash trace ring's global sequence. "
        "Per-CPU segments make every other word single-writer, and the "
        "sequence is the one shared value -- it is a fetch-add because a "
        "reporter that can block cannot report the deadlock it is in, which "
        "is the same reason Linux's printk ringbuffer is lock-free (see "
        "issues #465 and #486). Not boot-reachable: nothing here runs before "
        "main(), so issue #484's mmu_off hazard does not apply",
}


def main():
    if not KERNEL.is_dir():
        print("FAIL lock-discipline: kernel/ not found", file=sys.stderr)
        return 1

    failures = []
    checked_files = 0
    atomic_users = []
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

        # RULE 2
        if ATOMIC_RE.search(text):
            atomic_users.append(rel)
            if rel not in ATOMIC_ALLOWED:
                failures.append(
                    "%s uses a raw atomic intrinsic and is not in this "
                    "script's allowlist. Ordinary kernel code reaches an "
                    "atomic through kernel/lib/spinlock.tkb's lock or "
                    "through GitHub issue #299's publication record; if this "
                    "use really needs the raw instruction, add the file here "
                    "with the reason" % rel)

    stale = [name for name in ATOMIC_ALLOWED
             if not (KERNEL / name).exists()
             or not ATOMIC_RE.search((KERNEL / name).read_text())]
    for name in stale:
        failures.append(
            "%s is allowed to use raw atomics here but no longer does (or no "
            "longer exists): remove the entry rather than leaving a claim "
            "about nothing" % name)

    if failures:
        for f in failures:
            print("FAIL lock-discipline: %s" % f, file=sys.stderr)
        return 1

    print("PASS lock-discipline: %d files checked; no global Mutex is "
          "initialised, and %d files use a raw atomic, all of them declared"
          % (checked_files, len(atomic_users)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
