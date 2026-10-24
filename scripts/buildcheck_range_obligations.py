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
                                               and require a counterexample

z3 is the version pinned in scripts/fetch_model_tools.sh (TAKIBI_Z3 names
another binary). Verdicts are cached by obligation digest and z3 version
under the model-tools directory, so an unchanged obligation is not solved
twice; only `unsat` is cached.
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
import time

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
FETCH = ROOT / "scripts" / "fetch_model_tools.sh"
HEADER = "; takibi-range-obligation v1"
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


def check_dir(directory: pathlib.Path, z3: str,
              cache: pathlib.Path | None) -> list[str]:
    """Check every obligation; return the failure reports."""
    files = sorted(directory.glob("*.smt2"))
    if not files:
        return [f"no obligations in {directory}"]
    failures: list[str] = []
    todo: list[tuple[pathlib.Path, list[str], str]] = []
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
        if cache is not None and (cache / digest).exists():
            if is_init:
                # The cache entry of an init obligation holds its cold time.
                try:
                    INIT_STATS["seconds"] += float(
                        (cache / digest).read_text() or "0")
                except ValueError:
                    pass
            continue
        todo.append((path, sites, body))

    def one(item):
        path, sites, body = item
        return item, solve_timed(z3, body)

    workers = min(8, os.cpu_count() or 1)
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for (path, sites, body), (out, seconds) in pool.map(one, todo):
            is_init = body.startswith(INIT_HEADER)
            if is_init:
                INIT_STATS["seconds"] += seconds
            verdict = out.strip().splitlines()[0] if out.strip() else "no output"
            if verdict == "unsat":
                if cache is not None:
                    (cache / path.stem).write_text(
                        f"{seconds:.4f}" if is_init else "")
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

fn main() -> i32 {
    return wrap(10, 50) as i32;
}
"""


def control(takibi: str) -> int:
    """#935's rule planted: unsigned Sub keeps lo < 0. Must be sat."""
    z3, _ = find_z3()
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
    failures = [f for f in failures
                if f not in init_planted and f not in fact_planted]
    planted = [f for f in failures
               if ": sat " in f and "rule: sub" in f and "claim: {-60..<80 as usize}" in f
               and "counterexample" in f]
    if len(planted) != 1:
        print("\n".join(failures))
        print("FAIL range-obligation control: #935's planted rule was not "
              "reported with a counterexample")
        return 1
    print(planted[0])
    report_pass("range-obligation-control",
                "z3 reports #935's planted unsigned-Sub range, a planted "
                "init coverage claim (#954) and a planted path-fact claim "
                "(#975) with counterexamples",
                obligations=len(failures) + len(init_planted) + len(fact_planted))
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
