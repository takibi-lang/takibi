#!/usr/bin/env python3
"""Re-check every refinement range the compiler derived, with z3.

GitHub issue #952. `takibi --emit-range-obligations DIR` writes one SMT-LIB
file per distinct derived range (lib/range_obligation.ml; the format is in
docs/RANGE_OBLIGATIONS.md). Each file asserts that some input inside its
known range makes the machine operation, at its own bit width, land outside
the derived range. So:

  unsat           the range is proved
  sat             the checker's interval arithmetic is wrong; the
                  counterexample (z3's model) is printed with the sites
  unknown/timeout fails too: an obligation nobody proved is not proved

Usage:
  buildcheck_range_obligations.py DIR          check a compiler's output
  buildcheck_range_obligations.py --control TAKIBI
                                               failing control: compile a
                                               Sub with #935's rule planted
                                               and a max with #961's range
                                               (#984), and require a
                                               counterexample for each

z3 is the version pinned in scripts/fetch_model_tools.sh (TAKIBI_Z3 names
another binary). Verdicts are cached by obligation digest and z3 version
under the model-tools directory, so an unchanged obligation is not solved
twice; only `unsat` is cached. GitHub issue #985: the cache key and the
in-run sharing use the obligation's canonical form (atoms renamed), and the
obligations run in a few long-lived z3 processes, `(reset)` between them; any
verdict but `unsat` is re-solved alone for the report.
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import time

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
FETCH = ROOT / "scripts" / "fetch_model_tools.sh"
HEADER = "; takibi-range-obligation v2"
# GitHub issue #954: initialization coverage claims (lib/init_pred.ml) share
# the directory, naming and cache. Their cold z3 time has a budget, reported
# as a share like the #923 compile allocation budget.
INIT_HEADER = "; takibi-init-obligation v1"
INIT_BUDGET_SECONDS = 5.0
INIT_STATS = {"count": 0, "seconds": 0.0}
TIMEOUT_SECONDS = 20


def z3_version_pinned() -> str:
    match = re.search(r"^Z3_VERSION=(\S+)$", FETCH.read_text(), re.MULTILINE)
    if match is None:
        sys.exit("buildcheck_range_obligations: Z3_VERSION not found in "
                 "scripts/fetch_model_tools.sh")
    return match.group(1)


def tools_root() -> pathlib.Path:
    out = subprocess.run(["bash", str(FETCH)], check=True, text=True,
                         stdout=subprocess.PIPE)
    return pathlib.Path(out.stdout.strip().splitlines()[-1])


def find_z3() -> tuple[str, pathlib.Path | None]:
    """The z3 binary, and the cache directory (None: no cache)."""
    override = os.environ.get("TAKIBI_Z3")
    if override:
        return override, None
    version = z3_version_pinned()
    root = tools_root()
    z3 = root / f"z3-{version}" / "bin" / "z3"
    cache = root / f"range-obligation-cache-z3-{version}"
    cache.mkdir(exist_ok=True)
    return str(z3), cache


def split(text: str) -> tuple[list[str], str]:
    """Site lines, and the text whose MD5 is the obligation's identity."""
    sites, body = [], []
    for line in text.splitlines(keepends=True):
        if line.startswith("; site: "):
            sites.append(line[len("; site: "):].strip())
        else:
            body.append(line)
    return sites, "".join(body)


def solve(z3: str, text: str, extra: str = "") -> str:
    return solve_timed(z3, text, extra)[0]


def solve_timed(z3: str, text: str, extra: str = "") -> tuple[str, float]:
    start = time.monotonic()
    try:
        out = subprocess.run(
            [z3, f"-T:{TIMEOUT_SECONDS}", "-in"], input=text + extra,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=TIMEOUT_SECONDS + 10)
    except subprocess.TimeoutExpired:
        return "timeout", time.monotonic() - start
    return out.stdout, time.monotonic() - start


ATOM = re.compile(r"\bx_[A-Za-z0-9_]+\b")


def canonical(body: str) -> str:
    """GitHub issue #985: the obligation up to renaming of its atoms.

    Comments (rule, claim) go; the header's kind stays; every init atom
    (`x_...`) is renamed by its first occurrence. Two obligations with one
    canonical text are the same formula, so they share one z3 verdict, in the
    cache and within one run. The renaming is a bijection on names that no
    fixed name (`k`, `a`, `b`, `r`) shares, so it keeps satisfiability.
    """
    kind = body.splitlines()[0] if body else ""
    names: dict[str, str] = {}
    lines = [kind]
    for line in body.splitlines():
        if line.startswith(";"):
            continue
        lines.append(ATOM.sub(
            lambda m: names.setdefault(m.group(0), f"x_c{len(names)}"), line))
    return "\n".join(lines) + "\n"


def batch_solve(z3: str, bodies: list[str]) -> list[tuple[str, float]]:
    """GitHub issue #985: solve several obligations in one z3 process.

    Each is followed by `(reset)`, which returns z3 to its start state, so
    every obligation is checked exactly as by a fresh process; only process
    start-up is shared. Each verdict is timed from the write of its query to
    its answer line. A verdict that is not `unsat`, or a dead process, is
    left to the caller, which re-solves that obligation alone (the
    authoritative verdict and the counterexample come from that run).
    """
    results: list[tuple[str, float]] = []
    try:
        proc = subprocess.Popen(
            [z3, f"-t:{TIMEOUT_SECONDS * 1000}", "-in"], text=True,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT)
    except OSError:
        return [("no output", 0.0)] * len(bodies)
    assert proc.stdin is not None and proc.stdout is not None
    start = time.monotonic()
    try:
        for index, body in enumerate(bodies):
            # The marker delimits this obligation's output, so an error line
            # can never shift a later obligation's verdict onto this one.
            marker = f"takibi-obligation-end-{index}"
            proc.stdin.write(body + f'(echo "{marker}")\n(reset)\n')
            proc.stdin.flush()
            # A query z3 never answers (an unbalanced parenthesis swallows the
            # marker) must not hang the build: kill the process, which ends
            # the batch with "no output" for the rest.
            watchdog = threading.Timer(TIMEOUT_SECONDS + 10, proc.kill)
            watchdog.start()
            lines: list[str] = []
            while True:
                line = proc.stdout.readline()
                if not line or line.strip() == marker:
                    break
                lines.append(line.strip())
            watchdog.cancel()
            now = time.monotonic()
            verdict = lines[0] if len(lines) == 1 else "no output"
            if not line:
                verdict = "no output"
            results.append((verdict, now - start))
            start = now
            if not line:
                break
    except (BrokenPipeError, OSError):
        pass
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        proc.kill()
        proc.wait()
    results += [("no output", 0.0)] * (len(bodies) - len(results))
    return results


def check_dir(directory: pathlib.Path, z3: str,
              cache: pathlib.Path | None) -> list[str]:
    """Check every obligation; return the failure reports."""
    files = sorted(directory.glob("*.smt2"))
    if not files:
        return [f"no obligations in {directory}"]
    failures: list[str] = []
    # Canonical digest -> the obligations of that form (GitHub issue #985).
    groups: dict[str, list[tuple[pathlib.Path, list[str], str]]] = {}
    for path in files:
        text = path.read_text()
        sites, body = split(text)
        is_init = text.startswith(INIT_HEADER)
        if not text.startswith(HEADER) and not is_init:
            failures.append(f"{path.name}: not a v1 range or init obligation")
            continue
        digest = hashlib.md5(body.encode()).hexdigest()
        if digest != path.stem:
            failures.append(f"{path.name}: content digest is {digest}")
            continue
        if is_init:
            INIT_STATS["count"] += 1
        key = hashlib.md5(
            ("canonical-v1\n" + canonical(body)).encode()).hexdigest()
        groups.setdefault(key, []).append((path, sites, body))
    todo: list[tuple[str, list[tuple[pathlib.Path, list[str], str]]]] = []
    for key, members in groups.items():
        if cache is not None and (cache / key).exists():
            if members[0][2].startswith(INIT_HEADER):
                # The cache entry of an init obligation holds its cold time.
                try:
                    INIT_STATS["seconds"] += float(
                        (cache / key).read_text() or "0")
                except ValueError:
                    pass
            continue
        todo.append((key, members))

    # Init obligations run first, in one process of their own, so their
    # budgeted time is not inflated by the range obligations' parallel load.
    init_todo = [t for t in todo if t[1][0][2].startswith(INIT_HEADER)]
    range_todo = [t for t in todo if not t[1][0][2].startswith(INIT_HEADER)]

    def run_chunk(chunk):
        return chunk, batch_solve(z3, [m[0][2] for _, m in chunk])

    solved = list(zip(*run_chunk(init_todo))) if init_todo else []
    workers = max(1, min(8, os.cpu_count() or 1, len(range_todo)))
    chunks = [c for c in (range_todo[i::workers] for i in range(workers)) if c]
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        solved += [pair for chunk, verdicts in pool.map(run_chunk, chunks)
                   for pair in zip(chunk, verdicts)]

    retry: list[tuple[pathlib.Path, list[str], str]] = []
    for (key, members), (verdict, seconds) in solved:
        if members[0][2].startswith(INIT_HEADER):
            INIT_STATS["seconds"] += seconds
        if verdict == "unsat":
            if cache is not None:
                (cache / key).write_text(
                    f"{seconds:.4f}" if members[0][2].startswith(INIT_HEADER)
                    else "")
            continue
        retry += members

    def one(item):
        return item, solve_timed(z3, item[2])

    with concurrent.futures.ThreadPoolExecutor(min(8, os.cpu_count() or 1)) as pool:
        for (path, sites, body), (out, seconds) in pool.map(one, retry):
            is_init = body.startswith(INIT_HEADER)
            verdict = out.strip().splitlines()[0] if out.strip() else "no output"
            if verdict == "unsat":
                # The batch did not answer it (a dead process); this run did.
                if is_init:
                    INIT_STATS["seconds"] += seconds
                continue
            claim = next((l for l in body.splitlines()
                          if l.startswith("; claim:")), "")
            rule = next((l for l in body.splitlines()
                         if l.startswith("; rule:")), "")
            report = [f"{path.name}: {verdict}  ({rule[2:]}, {claim[2:]})"]
            report += [f"  at {s}" for s in sites]
            if verdict == "sat" and is_init:
                model = solve(z3, body, "(get-model)\n(get-value (k))\n")
                report.append("  counterexample (k: an element not covered):")
                report += ["    " + l for l in model.strip().splitlines()[1:]]
            elif verdict == "sat":
                model = solve(z3, body, "(get-model)\n(get-value (r))\n")
                report.append("  counterexample (a, b: inputs; r: result):")
                report += ["    " + l for l in model.strip().splitlines()[1:]]
            else:
                report.append("  " + out.strip().replace("\n", "\n  "))
            failures.append("\n".join(report))
    return failures


CONTROL_SOURCE = """\
fn wrap(a: {0..<100 as usize}, b: {20..<61 as usize}) -> usize {
    let d = a - b;
    return 0;
}

fn widest(x: u64, y: u64) -> u64 {
    let m = max(x & 3, y);
    return m;
}

fn fold956(x: u64) -> u64 {
    let m = x & (0xFFFFFFFFFFFFFFFF / 64);
    return m;
}

fn leaf961(x: u64) -> u64 {
    let m = max(x & 3, 0xFFFFFFFFFFFFFFFF);
    return m;
}

fn tail983(dst: borrow uninit [u8; 8..], n: usize) ensures init(dst[n..<8]) {
    if (n > 8) { return; }
    zero_fill(dst[n..<8]);
}

fn whole983(o: borrow uninit [u8; 8..]) ensures init(o[0..<8]) {
    tail983(o, 0xFFFFFFFFFFFFFFFF);
}

fn sub990(o: borrow uninit [u8; 8..], m: usize) ensures init(o[0..<8]) {
    tail983(o, m - 1);
    zero_fill(o[0..<8]);
}

fn main() -> i32 {
    return wrap(10, 50) as i32;
}
"""


def control(takibi: str) -> int:
    """#935's rule planted: unsigned Sub keeps lo < 0. Must be sat."""
    z3, _ = find_z3()
    # GitHub issue #985: one batch must keep one verdict per obligation, in
    # order, even past a sat answer and a malformed query.
    unsat_q = "(declare-const k Int)\n(assert (< k k))\n(check-sat)\n"
    sat_q = "(declare-const k Int)\n(assert (= k 7))\n(check-sat)\n"
    broken_q = "(assert (< undeclared 0))\n(check-sat)\n"
    got = [v for v, _ in batch_solve(z3, [unsat_q, sat_q, broken_q, unsat_q])]
    if got[0] != "unsat" or got[1] != "sat" or got[2] == "unsat" \
            or got[3] != "unsat":
        print(f"FAIL range-obligation control: batch verdicts {got}")
        return 1
    with tempfile.TemporaryDirectory(prefix="takibi-range-obl-") as tmp:
        tmp_path = pathlib.Path(tmp)
        src = tmp_path / "control.tkb"
        src.write_text(CONTROL_SOURCE)
        out_dir = tmp_path / "obligations"
        run = subprocess.run(
            [takibi, str(src), "-o", str(tmp_path / "control.o"),
             "--range-obligation-fault-control",
             "--emit-range-obligations", str(out_dir)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if run.returncode != 0:
            print(run.stdout)
            print("FAIL range-obligation control: the control did not compile")
            return 1
        # GitHub issue #954: a planted init coverage claim, [0, 8) shown
        # by [0, 7) only, in lib/init_pred.ml's format. z3 must name k = 7.
        planted_init = (INIT_HEADER + "\n; rule: init\n"
                        "; claim: init(planted[0..<8])\n"
                        "(set-logic QF_LIA)\n(declare-const k Int)\n"
                        "(assert (and (<= 0 k) (< k 8)))\n"
                        "(assert (not (or false (and (<= 0 k) (< k 7)))))\n"
                        "(check-sat)\n")
        digest = hashlib.md5(planted_init.encode()).hexdigest()
        (out_dir / f"{digest}.smt2").write_text(planted_init)
        # GitHub issue #975: a planted claim that needs a path fact it does
        # not have: [0, 20) by [0, s) with x >= 16 and s = min(x, 28). z3
        # must name an uncovered k in [16, 20).
        planted_fact = (INIT_HEADER + "\n; rule: init\n"
                        "; claim: init(planted_fact[0..<20])\n"
                        "(set-logic QF_LIA)\n"
                        "(declare-const x_s Int)\n(declare-const x_x Int)\n"
                        "(assert (and (<= 0 x_s) (< x_s 18446744073709551616)))\n"
                        "(assert (and (<= 0 x_x) (< x_x 18446744073709551616)))\n"
                        "(assert (>= (+ x_x (- 16)) 0))\n"
                        "(assert (= x_s (ite (<= x_x 28) x_x 28)))\n"
                        "(declare-const k Int)\n"
                        "(assert (and (<= 0 k) (< k 20)))\n"
                        "(assert (not (or false (and (<= 0 k) (< k x_s)))))\n"
                        "(check-sat)\n")
        digest = hashlib.md5(planted_fact.encode()).hexdigest()
        (out_dir / f"{digest}.smt2").write_text(planted_fact)
        failures = check_dir(out_dir, z3, None)
    init_planted = [f for f in failures
                    if ": sat " in f and "rule: init" in f
                    and "(k 7)" in f.replace("\n", " ")]
    if len(init_planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: the planted init coverage "
              "claim was not reported with k = 7")
        return 1
    fact_planted = [f for f in failures
                    if ": sat " in f and "planted_fact" in f
                    and re.search(r"\(k (16|17|18|19)\)", f.replace("\n", " "))]
    if len(fact_planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: the planted path-fact claim "
              "(#975) was not reported with k in [16, 20)")
        return 1
    # GitHub issue #984: #961's min/max placeholder, planted: max(x & 3, y)
    # on u64 claimed {0..<10^9}. z3 must give a counterexample.
    mm_planted = [f for f in failures
                  if ": sat " in f and "rule: max" in f
                  and "claim: {0..<1000000000 as u64}" in f
                  and "counterexample" in f]
    if len(mm_planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: #961's planted min/max range "
              "(#984) was not reported with a counterexample")
        return 1
    failures = [f for f in failures
                if f not in init_planted and f not in fact_planted
                and f not in mm_planted]
    planted = [f for f in failures
               if ": sat " in f and "rule: sub" in f and "claim: {-60..<80 as usize}" in f
               and "counterexample" in f]
    if len(planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: #935's planted rule was not "
              "reported with a counterexample")
        return 1
    print(planted[0])
    # GitHub issue #960: #956's native fold, planted: the mask
    # 0xFFFFFFFFFFFFFFFF / 64 read as 0 claims {0..<1}. The obligation spells
    # the mask's expression, so z3 folds it at u64 and refutes the claim.
    fold_planted = [f for f in failures
                    if ": sat " in f and "rule: band" in f
                    and "claim: {0..<1 as u64}" in f and "counterexample" in f]
    if len(fold_planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: #956's planted native fold "
              "(#960) was not reported with a counterexample")
        return 1
    # #961's native leaf, planted: max(x & 3, 0xFFFFFFFFFFFFFFFF) on u64
    # with the literal read as -1 claims {0..<4}; z3 reads the literal's
    # pattern at u64.
    leaf_planted = [f for f in failures
                    if ": sat " in f and "rule: max" in f
                    and "claim: {0..<4 as u64}" in f and "counterexample" in f]
    if len(leaf_planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: #961's planted native leaf "
              "(#960) was not reported with a counterexample")
        return 1
    # #983's native init leaf, planted: 0xFFFFFFFFFFFFFFFF passed as a
    # contract offset read as -1. z3 must report the reading k = -1 against
    # the literal's usize value.
    init_leaf_planted = [f for f in failures
                         if ": sat " in f and "rule: leaf" in f
                         and "0xffffffffffffffff" in f
                         and "(k (- 1))" in f.replace("\n", " ")]
    if len(init_leaf_planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: #983's planted native init "
              "leaf (#960) was not reported with k = -1")
        return 1
    # GitHub issue #990: a wrong no-wrap judgement, planted: every `a - b`
    # judged not to wrap, so `m - 1` with no fact on m becomes a term (m = 0 wraps). The
    # no-wrap obligation must report the wrapped value k = -1.
    nowrap_planted = [f for f in failures
                      if ": sat " in f and "rule: nowrap-sub" in f
                      and "(k (- 1))" in f.replace("\n", " ")]
    if not nowrap_planted:
        print("\n".join(failures))
        print("FAIL range-obligation control: #990's planted no-wrap "
              "judgement was not reported with k = -1")
        return 1
    report_pass("range-obligation-control",
                "z3 reports #935's planted unsigned-Sub range, #961's "
                "planted min/max range (#984), the three planted native "
                "constant readings of #956, #961 and #983 (#960), a planted "
                "no-wrap judgement (#990), a planted "
                "init coverage claim (#954) and a planted path-fact claim "
                "(#975) with counterexamples",
                obligations=len(failures) + len(init_planted)
                + len(fact_planted) + len(mm_planted))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--control":
        return control(argv[2])
    if len(argv) != 2:
        print(__doc__)
        return 2
    directory = pathlib.Path(argv[1])
    z3, cache = find_z3()
    failures = check_dir(directory, z3, cache)
    if failures:
        print("\n".join(failures))
        print(f"FAIL range-obligations: {len(failures)} derived range(s) not "
              f"proved by z3 in {directory}")
        return 1
    share = 100.0 * INIT_STATS["seconds"] / INIT_BUDGET_SECONDS
    if INIT_STATS["seconds"] > INIT_BUDGET_SECONDS:
        print(f"FAIL init-obligation-budget: {INIT_STATS['count']} init "
              f"obligation(s) took {INIT_STATS['seconds']:.2f} s of cold z3 "
              f"time, over the {INIT_BUDGET_SECONDS:.1f} s budget "
              f"({share:.0f}%; docs/VERIFICATION_DESIGN.md)")
        return 1
    report_pass("range-obligations",
                f"z3 proves every derived refinement range in {directory}",
                obligations=len(list(directory.glob('*.smt2'))))
    if INIT_STATS["count"]:
        report_pass("init-obligation-budget",
                    f"{INIT_STATS['seconds']:.2f} s cold z3 time, "
                    f"{share:.0f}% of the {INIT_BUDGET_SECONDS:.1f} s budget",
                    obligations=INIT_STATS["count"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
