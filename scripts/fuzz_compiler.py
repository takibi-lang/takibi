#!/usr/bin/env python3
"""Seeded native soundness probes, with an independent C execution oracle.

Generated sources and rejection logs stay below the requested output directory.
This is bounded testing, not a proof of compiler soundness.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FAMILIES = ("refined", "arithmetic", "array", "slice", "loop", "variant", "inclusive")


def generate(rng: random.Random, family: str) -> tuple[str, list[tuple[int, int]]]:
    """Return source and mathematical input/output pairs; no checker feedback."""
    size = rng.randint(2, 12)
    bias = rng.randint(1, 20)
    values = [bias + i * 3 for i in range(size)]
    prefix = (
        "// Generated compiler soundness probe.\n"
        "extern fn fuzz_observe(value: i32, lo: i32, hi: i32);\n"
        f"fn checked(x: {{0..<{size} as i32}}) -> i32 {{\n"
        f"    fuzz_observe(x, 0, {size});\n"
        "    return x;\n}\n"
    )
    inputs = sorted(set([-2, -1, 0, 1, size - 1, size, size + 1]
                        + [rng.randint(-3, size + 3) for _ in range(5)]))
    if family in ("refined", "inclusive"):
        # Inclusive guards intentionally probe rejection at the upper boundary.
        op = "<=" if family == "inclusive" else "<"
        body = f"if (x >= 0 && x {op} {size}) {{ return checked(x); }}"
        expected = [(x, x if 0 <= x < size + (op == "<=") else -1)
                    for x in inputs]
    elif family == "arithmetic":
        # Compute intervals mathematically, independently of Takibi's inference.
        lo, hi = 0, size
        expression = "x"
        operations = []
        arithmetic = []
        for step in range(rng.randint(1, 5)):
            op = rng.choice(("+", "-", "*"))
            amount = rng.randint(1, 4)
            arithmetic.append((op, amount))
            if op == "+":
                lo, hi = lo + amount, hi + amount
            elif op == "-":
                lo, hi = lo - amount, hi - amount
            else:
                lo, hi = lo * amount, (hi - 1) * amount + 1
            name = f"y{step}"
            lower = str(lo) if lo >= 0 else f"(0 - {-lo})"
            upper = str(hi) if hi >= 0 else f"(0 - {-hi})"
            operations.append(f"let {name}: {{{lower}..<{upper} as i32}} = {expression} {op} {amount};")
            operations.append(f"fuzz_observe({name}, {lo}, {hi});")
            expression = name
        body = (f"if (x >= 0 && x < {size}) {{\n" + "\n".join(operations)
                + f"\nreturn {expression};\n}}")
        def calculate(x: int) -> int:
            if not 0 <= x < size:
                return -1
            for op, n in arithmetic:
                x = x + n if op == "+" else x - n if op == "-" else x * n
            return x
        expected = [(x, calculate(x)) for x in inputs]
    elif family in ("array", "slice"):
        elements = ", ".join(str(v) for v in values)
        body = f"let mut a: [i32; {size}] = {{{elements}}};\n"
        place = "a"
        if family == "slice":
            body += "let s: []i32 = a as []i32;\n"
            place = "s"
        body += (f"if (x >= 0 && x < {size}) {{\n"
                 "    checked(x);\n"
                 f"    return {place}[x as usize];\n}}")
        expected = [(x, values[x] if 0 <= x < size else -1) for x in inputs]
    elif family == "loop":
        body = (f"let mut a: [i32; {size}];\n"
                f"for i: usize in 0..<{size} {{\n"
                f"    fuzz_observe(i as i32, 0, {size});\n"
                f"    a[i] = {bias} + i as i32;\n}}\n"
                f"if (x >= 0 && x < {size}) {{ return a[x as usize]; }}")
        expected = [(x, bias + x if 0 <= x < size else -1) for x in inputs]
    else:
        prefix += ("variant Choice { Value(i32); Missing; }\n"
                   "fn choose(x: i32) -> Choice {\n"
                   f"    if (x >= 0 && x < {size}) {{ return Choice::Value(checked(x)); }}\n"
                   "    return Choice::Missing;\n}\n")
        body = ("    let v: Choice = choose(x);\n"
                "    match v {\n"
                f"        Choice::Value(n) => {{ return n + {bias}; }}\n"
                "        Choice::Missing => { return -1; }\n"
                "    }")
        expected = [(x, x + bias if 0 <= x < size else -1) for x in inputs]
    return prefix + "fn fuzz_entry(x: i32) -> i32 {\n" + body + "\nreturn -1;\n}\n", expected


def driver(pairs: list[tuple[int, int]]) -> str:
    rows = ",\n".join(f"{{{x}, {y}}}" for x, y in pairs)
    return '''/* Independent oracle: compiled by the host C compiler. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
extern int32_t fuzz_entry(int32_t);
void fuzz_observe(int32_t value, int32_t lo, int32_t hi) {
    if (value < lo || value >= hi) {
        fprintf(stderr, "refinement violated: %d outside [%d,%d)\\n", value, lo, hi);
        exit(90);
    }
}
int main(void) {
    const int32_t cases[][2] = {''' + rows + '''};
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        int32_t actual = fuzz_entry(cases[i][0]);
        if (actual != cases[i][1]) {
            fprintf(stderr, "result mismatch: input=%d expected=%d actual=%d\\n",
                    cases[i][0], cases[i][1], actual);
            return 91;
        }
    }
    return 0;
}
'''


def command(args: list[str], timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def evaluate(compiler: Path, source: str, harness: str, directory: Path,
             timeout: float) -> tuple[str, str]:
    directory.mkdir(parents=True, exist_ok=True)
    tkb, c, obj, exe = [directory / name for name in ("case.tkb", "oracle.c", "case.o", "case.exe")]
    tkb.write_text(source)
    c.write_text(harness)
    try:
        result = command([str(compiler), str(tkb), "--target", "x86_64-pc-linux-gnu",
                          "--forbid-trap", "-o", str(obj)], timeout)
        output = result.stdout + result.stderr
        (directory / "compile.log").write_text(output)
        if result.returncode:
            # Compiler crashes and internal failures are not normal rejections.
            if result.returncode < 0 or any(word in output for word in
                                           ("BUG", "Fatal error", "LLVM ERROR")):
                return "compiler-failure", output
            if "Syntax error" in output:
                return "generator-failure", output
            if ("Error:" not in output and "error:" not in output
                    and not re.search(r'File ".*", line \d+, character \d+:', output)):
                return "compiler-failure", output
            return "rejected", output
        result = command(["cc", "-std=c11", "-O0", "-no-pie", str(c), str(obj),
                          "-o", str(exe)], timeout)
        if result.returncode:
            return "link-failure", result.stdout + result.stderr
        result = command([str(exe)], timeout)
        output = result.stdout + result.stderr
        if result.returncode and not output:
            output = f"execution failed: exit={result.returncode}\n"
        (directory / "run.log").write_text(output)
        return ("accepted" if result.returncode == 0 else "runtime-failure"), output
    except subprocess.TimeoutExpired as exc:
        return "timeout", f"command timed out: {exc.cmd}"


def minimize(compiler: Path, source: str, harness: str, directory: Path,
             timeout: float, failure_detail: str, budget: int = 64) -> str:
    """Bounded line deletion; retain only accepted programs with a runtime failure.

    Syntax/type errors and link failures cannot justify a reduction. The C
    harness is retained verbatim, so the input and oracle do not move.
    """
    lines = source.splitlines(keepends=True)
    diagnosis = failure_detail.split(":", 1)[0]
    attempts = 0
    width = max(1, len(lines) // 2)
    while width and attempts < budget:
        changed = False
        for start in range(0, len(lines), width):
            candidate = lines[:start] + lines[start + width:]
            attempts += 1
            status, detail = evaluate(compiler, "".join(candidate), harness,
                                      directory, timeout)
            if status == "runtime-failure" and detail.split(":", 1)[0] == diagnosis:
                lines = candidate
                changed = True
                break
            if attempts >= budget:
                break
        if not changed:
            width //= 2
    result = "".join(lines)
    (directory.parent / "minimized.tkb").write_text(result)
    return result


def campaign(compiler: Path, seed: int, cases: int, output: Path,
             seconds: float, timeout: float, *, reduce: bool = True) -> dict:
    rng = random.Random(seed)
    summary = {"seed": seed, "accepted": 0, "rejected": 0, "families": {},
               "executed_families": {}}
    deadline = time.monotonic() + seconds
    for index in range(cases):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"campaign exceeded {seconds}s before completing {cases} cases")
        family = FAMILIES[index % len(FAMILIES)]
        source, pairs = generate(rng, family)
        directory = output / f"{index:05d}-{family}"
        harness = driver(pairs)
        status, detail = evaluate(compiler, source, harness, directory, timeout)
        summary["families"][family] = summary["families"].get(family, 0) + 1
        if status not in ("accepted", "rejected"):
            summary["failure"] = {"case": index, "family": family, "status": status,
                                  "detail": detail, "directory": str(directory)}
            if reduce and status == "runtime-failure":
                minimize(compiler, source, harness, directory / "reduction", timeout, detail)
            break
        summary[status] += 1
        if status == "accepted":
            summary["executed_families"][family] = summary["executed_families"].get(family, 0) + 1
    output.mkdir(parents=True, exist_ok=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def seeded_control(compiler: Path, seed: int, output: Path, timeout: float) -> None:
    """Build an isolated compiler with the <= upper-bound rule off by one."""
    with tempfile.TemporaryDirectory(prefix="takibi-fuzz-mutant-") as temp:
        scratch = Path(temp)
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                capture_output=True, text=True, check=True).stdout.strip()
        archive = subprocess.run(["git", "archive", "HEAD"], cwd=ROOT,
                                 capture_output=True, check=True)
        subprocess.run(["tar", "-x", "-C", str(scratch)], input=archive.stdout, check=True)
        for file, pattern in (
            ("lib/type_inf.ml", "| Ast.Le -> update n None           (Some d)       acc"),
            ("lib/llvm_gen.ml", "| Le -> update n None           (Some d)       acc"),
        ):
            path = scratch / file
            text = path.read_text()
            if text.count(pattern) != 1:
                raise RuntimeError(f"seeded rule no longer unique: {file}")
            path.write_text(text.replace(pattern, pattern.replace("(Some d)", "(Some (d - 1))")))
        result = subprocess.run(["dune", "build", "-j", "1", "bin/main.exe"], cwd=scratch,
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError("scratch compiler build failed:\n" + result.stderr)
        result = campaign(scratch / "_build/default/bin/main.exe", seed, 14,
                          output / "mutant", 60, timeout)
        failure = result.get("failure", {})
        if (failure.get("status") != "runtime-failure"
                or "refinement violated:" not in failure.get("detail", "")):
            raise RuntimeError("seeded control did not find the injected interval defect")
        minimized = Path(failure["directory"]) / "minimized.tkb"
        harness = (Path(failure["directory"]) / "oracle.c").read_text()
        status, detail = evaluate(scratch / "_build/default/bin/main.exe",
                                  minimized.read_text(), harness,
                                  output / "mutant-replay", timeout)
        if status != "runtime-failure" or "refinement violated:" not in detail:
            raise RuntimeError("minimized counterexample did not reproduce the seeded defect")
        status, detail = evaluate(compiler, minimized.read_text(), harness,
                                  output / "original-replay", timeout)
        if status != "rejected" or "refined int range mismatch" not in detail:
            raise RuntimeError("original compiler did not reject the minimized seeded defect")
        (output / "control.json").write_text(json.dumps({
            "source_commit": commit, "seed": seed, "case_budget": 14,
            "failure_case": failure["case"], "minimized": str(minimized),
            "mutant_replay": "refinement violated", "original_replay": "rejected",
        }, indent=2) + "\n")
        print(f"PASS compiler-fuzz control: injected <= defect found at case {failure['case']}; minimized source retained")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=ROOT / "_build/default/bin/main.exe")
    parser.add_argument("--seed", type=int, default=646)
    parser.add_argument("--cases", type=int, default=42)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--command-timeout", type=float, default=5)
    parser.add_argument("--output", type=Path, help="exact artifact directory (default: a fresh run directory)")
    parser.add_argument("--control", action="store_true")
    args = parser.parse_args()
    if args.cases < len(FAMILIES) or args.seconds <= 0 or args.command_timeout <= 0:
        parser.error("require at least seven cases and positive time bounds")
    try:
        if args.output is None:
            base = ROOT / "_build/compiler-fuzz"
            base.mkdir(parents=True, exist_ok=True)
            args.output = Path(tempfile.mkdtemp(prefix=f"seed-{args.seed}-", dir=base))
        print(f"compiler-fuzz: seed={args.seed}, cases={args.cases}, artifacts={args.output}", flush=True)
        result = campaign(args.compiler.resolve(), args.seed, args.cases,
                          args.output, args.seconds, args.command_timeout)
        if "failure" in result:
            print("FAIL compiler-fuzz: " + json.dumps(result["failure"]))
            return 1
        if not result["accepted"]:
            raise RuntimeError("no accepted program was executed")
        missing = set(FAMILIES[:-1]) - result["executed_families"].keys()
        if missing:
            raise RuntimeError(f"no executed program for families: {sorted(missing)}")
        if args.control:
            seeded_control(args.compiler.resolve(), args.seed, args.output, args.command_timeout)
        print(f"PASS compiler-fuzz: seed={args.seed}, {result['accepted']} accepted and executed, "
              f"{result['rejected']} rejected; {len(result['families'])} families; logs={args.output}")
        return 0
    except (RuntimeError, subprocess.SubprocessError, OSError) as exc:
        print(f"FAIL compiler-fuzz: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
