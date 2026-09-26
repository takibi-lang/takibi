#!/usr/bin/env python3
"""Every ext2 mutation runs under kernel/fs/ext2/mutation_lock.tkb's guard.

GitHub issue #533. ext2_claim_directory mints a directory owner from the
directory tree, which is sound only while one core at a time mutates. That
used to be an ADMISSION claim -- every process reaching the filesystem
admitted to core 0 -- and is now a lock. The guard is linear, so a path that
takes it and forgets to release it does not compile.

What the compiler does NOT check is the other direction: a mutating syscall
arm added later would compile perfectly well WITHOUT taking the guard, and
would simply fail to exclude. The five arms that exist today are correct by
review, and review is exactly what stops being done. So this is the check
that the set stays closed.

The rule: every call to a mutator, outside the file that defines them, is
inside a function that takes the guard, or that is handed one as a
`borrow Ext2MutationGuard[ext2_mutation_lock]` parameter -- or its file is
named below with a reason. The parameter form counts because the compiler
checks it: the guard is linear and minted only by the take, so a caller
cannot produce one it does not hold (GitHub issue #597, whose mutating arms
take the guard before their path lookup and pass it down). One exemption exists and is real: the boot fixture mutates before any
peer can reach a filesystem, which is the same argument the admission claim
used to make for the whole kernel.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

# The operations that rewrite the directory tree or a file's blocks. Readers
# are deliberately absent: they take no lock by design, because
# peer_filesystem.expected measures both CPUs contending for the block device
# and a lock across reads would zero one side of that.
MUTATORS = (
    "ext2_resize_small_file",
    "ext2_create_root_file",
    "ext2_unlink_root_file",
    "ext2_create_file_in",
    "ext2_unlink_file_in",
    "ext2_make_directory_in",
    "ext2_claim_directory",
    "ext2_unlink_name",
    "ext2_rename_in",
    "ext2_remove_directory_in",
)

TAKE = "ext2_mutation_take()"
HELD = "guard: borrow Ext2MutationGuard[ext2_mutation_lock]"

# The file that defines the mutators, and the one that defines the lock: both
# name these functions without calling them.
DEFINING = {
    "fs/ext2/ext2.tkb",
    "fs/ext2/mutation_lock.tkb",
}

# Files permitted to mutate without the guard, and why.
UNGUARDED_ALLOWED = {
    "init/ext2_fixture.tkb":
        "the remaining file-creation fixture exercises O_CREAT-unreachable "
        "ext2 APIs before userspace can reach the filesystem",
}

FUNCTION_RE = re.compile(r"^(?:private )?fn ([A-Za-z_0-9]+)")


def strip_comment(line: str) -> str:
    """Drop a // comment, so prose naming a mutator is not a call."""
    return line.split("//", 1)[0]


def guard_problems(sources: dict[str, str]) -> tuple[list[str], int]:
    """Problems found, and how many guarded call sites were seen."""
    problems = []
    guarded = 0
    for rel, text in sorted(sources.items()):
        if rel in DEFINING:
            continue
        lines = text.splitlines()
        # Function spans, so a call site can name the function it is in.
        starts = [(index, match.group(1))
                  for index, line in enumerate(lines)
                  if (match := FUNCTION_RE.match(line))]
        bodies = {}
        for position, (index, name) in enumerate(starts):
            end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
            bodies[name] = (index, end, "\n".join(lines[index:end]))

        for index, line in enumerate(lines):
            code = strip_comment(line)
            for mutator in MUTATORS:
                if f"{mutator}(" not in code:
                    continue
                holder = None
                for name, (start, end, body) in bodies.items():
                    if start <= index < end:
                        holder = (name, body)
                        break
                if holder is None:
                    problems.append(
                        f"{rel}:{index + 1} calls {mutator} outside any "
                        "function, so nothing can take the guard")
                    continue
                name, body = holder
                signature = body.split("{", 1)[0]
                if TAKE in body or HELD in signature:
                    guarded += 1
                    continue
                if rel in UNGUARDED_ALLOWED:
                    continue
                problems.append(
                    f"{rel}:{index + 1} calls {mutator} in {name}, which does "
                    f"not take kernel/fs/ext2/mutation_lock.tkb's guard. An "
                    "ext2 mutation that excludes nothing re-opens GitHub "
                    "issue #533: two claims of one directory entry are two "
                    "owners of one block. Take the guard, or add this file to "
                    "UNGUARDED_ALLOWED in this script with the reason it "
                    "cannot race a peer")
    return problems, guarded


def main() -> int:
    if not KERNEL.is_dir():
        print("FAIL ext2-mutation-guard: kernel/ not found", file=sys.stderr)
        return 1

    sources = {
        str(path.relative_to(KERNEL)): path.read_text(encoding="utf-8")
        for path in sorted(KERNEL.rglob("*.tkb"))
    }
    problems, guarded = guard_problems(sources)
    for problem in problems:
        print(f"ERROR ext2-mutation-guard: {problem}")
    if problems:
        print("FAIL ext2-mutation-guard: an ext2 mutation is not excluded")
        return 1

    # Negative control: removing the guard from one helper must be caught.
    # Without this, a rule that stopped matching anything would pass forever.
    broken = dict(sources)
    target = "kernel/syscall.tkb"
    if TAKE not in broken.get(target, ""):
        print("FAIL ext2-mutation-guard: the negative control's subject "
              f"({target}) no longer takes the guard at all")
        return 1
    broken[target] = broken[target].replace(f"let guard = {TAKE};", "", 1)
    control, _ = guard_problems(broken)
    if not control:
        print("FAIL ext2-mutation-guard: a helper stripped of its guard was "
              "still accepted, so this check proves nothing")
        return 1

    # The same for the parameter form: a helper whose borrowed guard is
    # replaced by a plain word must be caught.
    if HELD not in broken.get(target, ""):
        print("FAIL ext2-mutation-guard: the negative control's subject "
              f"({target}) no longer receives the guard as a parameter")
        return 1
    unborrowed = dict(sources)
    unborrowed[target] = unborrowed[target].replace(HELD, "guard: usize", 1)
    control, _ = guard_problems(unborrowed)
    if not control:
        print("FAIL ext2-mutation-guard: a helper whose guard parameter was "
              "removed was still accepted")
        return 1

    def calls_a_mutator(text: str) -> bool:
        # Per LINE, because strip_comment on a whole file truncates it at the
        # first comment -- which made this read the boot fixture's header and
        # conclude it no longer mutates.
        for line in text.splitlines():
            code = strip_comment(line)
            if any(f"{mutator}(" in code for mutator in MUTATORS):
                return True
        return False

    stale = [name for name in UNGUARDED_ALLOWED
             if not calls_a_mutator(sources.get(name, ""))]
    for name in stale:
        print(f"ERROR ext2-mutation-guard: {name} is allowed to mutate "
              "without the guard but no longer does (or no longer exists): "
              "remove the entry rather than leaving a claim about nothing")
    if stale:
        return 1

    report_pass(
        "ext2-mutation-guard",
        f"{guarded} guarded mutation call site(s), "
        f"{len(UNGUARDED_ALLOWED)} file exempt with a stated reason, and a "
        "helper stripped of its guard, taken or borrowed, is refused",
        guarded_call_sites=guarded,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
