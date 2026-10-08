#!/usr/bin/env python3
"""DDB's process view must name the signals the kernel actually accepts.

GitHub issue #564: a napping process carrying a SIGTERM its parent had
already sent is indistinguishable from one that was never signalled, because
`kernel_process_current_termination_signal_take` refuses a SIGTERM the mask
blocks. `ps` now prints both words, and printing them created a second place
the signal vocabulary is written down.

GitHub issue #629 made kill(2) accept every standard signal 1..31 but the
job-control ones, and the view name all 31. The accepted set is derived from
`kill_signal_accepted` in kernel/kernel/syscall.tkb: its upper bound and the
numbers its refusing arm lists. The words live in `ddb_signal_name` in
kernel/arch/arm64/kernel/exception_evidence.tkb, one `match` arm per number.
A signal the kernel accepts and does not name would print as a bare hex
remainder where a word should be, which is the opacity the rendering exists
to remove, reintroduced silently and only visible to whoever is mid-stall.

The word is DERIVED, not merely present: each number must be spelled with
its Linux name (the ABI table below). That is what makes this a check
rather than a count -- a word beside the wrong number fails, and so does an
accepted signal with no word.

The remainder is checked too. `ddb_put_signal_set` names bits
0..DDB_STANDARD_SIGNALS-1 and prints what is left as hex, so the mask it
subtracts must be exactly those bits: one too few prints a signal twice, and
one too many drops a bit from a view whose whole claim is that nothing is.
"""

import ast
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
SYSCALL = ROOT / "kernel" / "kernel" / "syscall.tkb"
DEBUGGER = ROOT / "kernel" / "arch" / "arm64" / "kernel" / "exception_evidence.tkb"

RUNNER = ROOT / "scripts" / "ddb_qemu_checks.py"
RENDERER = "ddb_put_signal_set"


# The Linux signal numbers of the standard signals: an ABI, not a choice.
LINUX_NAMES = {
    1: "hup", 2: "int", 3: "quit", 4: "ill", 5: "trap", 6: "abrt", 7: "bus",
    8: "fpe", 9: "kill", 10: "usr1", 11: "segv", 12: "usr2", 13: "pipe",
    14: "alrm", 15: "term", 16: "stkflt", 17: "chld", 18: "cont", 19: "stop",
    20: "tstp", 21: "ttin", 22: "ttou", 23: "urg", 24: "xcpu", 25: "xfsz",
    26: "vtalrm", 27: "prof", 28: "winch", 29: "io", 30: "pwr", 31: "sys",
}


def accepted(text: str) -> set[int]:
    """The signals kill(2) lets through."""
    body = re.search(r"fn kill_signal_accepted\(signum: usize\) -> bool \{(.*?)\n\}",
                     text, re.DOTALL)
    if body is None:
        raise ValueError(
            "no kill_signal_accepted in kernel/kernel/syscall.tkb; this check "
            "reads the match that decides which signals exist and it has moved")
    refused = re.search(r"^\s*([0-9 |]+) => \{ return false; \}", body.group(1), re.M)
    bound = re.search(r"_ => \{ return signum <= (\d+); \}", body.group(1))
    if refused is None or bound is None:
        raise ValueError(
            "kill_signal_accepted is no longer one refusing arm and a "
            "`signum <= N` default; the accepted set cannot be derived")
    numbers = {int(n) for n in refused.group(1).split("|")}
    return set(range(1, int(bound.group(1)) + 1)) - numbers


def vocabulary(text: str) -> tuple[int, int, dict[int, str], str]:
    """(DDB_STANDARD_SIGNALS, its bits constant, number -> word, renderer)."""
    standard = re.search(r"const DDB_STANDARD_SIGNALS: usize = (\d+);", text)
    bits = re.search(r"const DDB_STANDARD_SIGNAL_BITS: usize = (0x[0-9A-Fa-f]+|\d+);", text)
    names = re.search(r"fn ddb_signal_name\(signum: usize\) -> \*u8 \{(.*?)\n\}",
                      text, re.DOTALL)
    body = re.search(rf"fn {RENDERER}\(set: usize\)[^{{]*\{{(.*?)\n\}}",
                     text, re.DOTALL)
    if standard is None or bits is None or names is None:
        raise ValueError("DDB_STANDARD_SIGNALS, DDB_STANDARD_SIGNAL_BITS or "
                         "ddb_signal_name is missing or reshaped")
    if body is None:
        raise ValueError(f"{RENDERER}(set: usize) is missing or reshaped")
    words = {int(n): w for n, w in re.findall(
        r"^\s*(\d+) => \{ return \"sig([a-z0-9]+)\" as \*u8; \}",
        names.group(1), re.M)}
    return int(standard.group(1)), int(bits.group(1), 0), words, body.group(1)


def declared(text: str) -> dict[str, int]:
    """The DDB_SIGNAL_ constants scripts/kernel_state.gdb spells from."""
    return {name: int(value) for name, value in
            re.findall(r"const DDB_SIGNAL_(\w+): usize = (\d+);", text)}


def runner_problems(text: str, numbers: set[int]) -> list[str]:
    """Use rendered sets, so a stale alternative in either gate cannot pass."""
    tree = ast.parse(text)
    shapes = [ast.literal_eval(node.value) for node in ast.walk(tree)
              if isinstance(node, ast.Assign) and any(
                  isinstance(target, ast.Name) and target.id == "SIGNALS"
                  for target in node.targets)]
    real_patterns = [node.args[0].value for node in ast.walk(tree)
                     if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                     and node.func.id == "has" and node.args
                     and isinstance(node.args[0], ast.Constant)
                     and isinstance(node.args[0].value, str)
                     and node.args[0].value.startswith("^ddb: ps pid=1 ppid=0 .* masked=")]
    if len(shapes) != 1 or len(real_patterns) != 1:
        return ["runner signal vocabulary predicates are missing or reshaped"]
    shape, real = shapes[0], real_patterns[0]
    names = ["sig" + LINUX_NAMES[n] for n in sorted(LINUX_NAMES)]
    # Every word alone, every adjacent pair, and the whole set, each with
    # and without a remainder: what the renderer can print, without walking
    # all 2**31 subsets.
    sets = [[name] for name in names]
    sets += [names[i:i + 2] for i in range(len(names) - 1)]
    sets.append(names)
    for words in sets:
        rendered = ",".join(words)
        for value in (rendered, rendered + "+0x0000000080000000"):
            if re.fullmatch(shape, value) is None:
                return [f"runner signal vocabulary rejects the real DDB set {value}"]
    for value in ("none", "0x0000000080000000"):
        if re.fullmatch(shape, value) is None:
            return [f"runner signal vocabulary rejects the real DDB set {value}"]
    for name in names:
        line = f"ddb: ps pid=1 ppid=0 state=3 masked={name}+0x0000000080000000 owner=none"
        if re.search(real, line) is None:
            return [f"runner signal vocabulary does not exercise PID 1 mask {name}"]
    if re.fullmatch(shape, "sigunknown") is not None:
        return ["runner signal vocabulary accepts an unknown named signal"]
    return []


def main() -> int:
    try:
        numbers = accepted(SYSCALL.read_text(encoding="ascii"))
        debugger = DEBUGGER.read_text(encoding="ascii")
        standard, bits, words, renderer = vocabulary(debugger)
        constants = declared(debugger)
    except (OSError, ValueError) as error:
        print(f"FAIL ddb-signal-names: {error}")
        return 1

    problems = []
    for number in sorted(numbers):
        if number not in words:
            problems.append(
                f"kill(2) accepts signal {number} and ddb_signal_name has no "
                f"arm for it: the process view would print it as a bare hex "
                f"remainder")
    for number in range(1, standard + 1):
        want = LINUX_NAMES.get(number)
        if number not in words:
            if number not in numbers:
                problems.append(f"ddb_signal_name has no arm for standard "
                                f"signal {number}")
        elif words[number] != want:
            problems.append(f"signal {number} is printed as `sig{words[number]}` "
                            f"rather than `sig{want}`: the view would name "
                            f"the wrong bit")
    for number in sorted(set(words) - set(range(1, standard + 1))):
        problems.append(f"ddb_signal_name names {number}, outside the "
                        f"{standard} standard signals the renderer walks")
    if numbers and max(numbers) > standard:
        problems.append(f"kill(2) accepts signals up to {max(numbers)} and the "
                        f"renderer names only 1..{standard}")
    # The GDB view spells the constant's name, lowercased; it must be the
    # same word for the same number.
    for name, number in sorted(constants.items()):
        if LINUX_NAMES.get(number) is None or name != "SIG" + LINUX_NAMES[number].upper():
            problems.append(f"DDB_SIGNAL_{name} is {number}, which is "
                            f"not that signal's Linux number: the GDB view "
                            f"would name the wrong bit")
    for number in range(1, standard + 1):
        if number in LINUX_NAMES and "SIG" + LINUX_NAMES[number].upper() not in constants:
            problems.append(f"no DDB_SIGNAL_SIG{LINUX_NAMES[number].upper()}: "
                            f"the GDB view would print signal {number} as "
                            f"hex where DDB prints a word")
    if standard != len(LINUX_NAMES):
        problems.append(f"DDB_STANDARD_SIGNALS is {standard}, not the "
                        f"{len(LINUX_NAMES)} standard Linux signals")
    if bits != (1 << standard) - 1:
        problems.append(
            f"DDB_STANDARD_SIGNAL_BITS is {bits:#x}, not the {standard} named "
            f"bits {(1 << standard) - 1:#x}: the view would print a signal "
            f"twice or drop a bit hidden from a view that claims to drop "
            f"nothing")
    if ("0..<DDB_STANDARD_SIGNALS" not in renderer or
            "set & ~DDB_STANDARD_SIGNAL_BITS" not in renderer):
        problems.append(f"{RENDERER} no longer walks DDB_STANDARD_SIGNALS and "
                        f"subtracts DDB_STANDARD_SIGNAL_BITS")

    try:
        problems.extend(runner_problems(RUNNER.read_text(encoding="ascii"), numbers))
    except (OSError, re.error, SyntaxError, ValueError) as error:
        problems.append(f"runner signal vocabulary: {error}")

    if problems:
        for problem in problems:
            print(f"ERROR\tddb-signal-names: {problem}")
        print(f"FAIL ddb-signal-names: {len(problems)} signal(s) are not "
              f"named as the kernel accepts them")
        return 1
    report_pass("ddb-signal-names",
                f"{len(numbers)} signal(s) kill(2) accepts are each named by "
                f"their Linux name among the {standard} the process view "
                f"walks, and its remainder is exactly the rest",
                signals=len(numbers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
