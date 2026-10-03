#!/usr/bin/env python3
"""Execution controls for the generated-program runner and its reduction oracle."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fuzz_compiler as fuzz


class ExecutionControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="takibi-fuzz-controls-")
        self.directory = Path(self.temp.name)
        self.compiler = fuzz.ROOT / "_build/default/bin/main.exe"
        self.source = "// Native oracle control.\nfn fuzz_entry(x: i32) -> i32 { return x; }\n"

    def tearDown(self):
        self.temp.cleanup()

    def evaluate(self, source=None, harness=None, timeout=5):
        return fuzz.evaluate(self.compiler, source or self.source,
                             harness or fuzz.driver([(0, 0), (1, 1)]),
                             self.directory / "case", timeout)

    def test_accepted_program_runs(self):
        self.assertEqual(self.evaluate()[0], "accepted")

    def test_wrong_result_is_not_a_rejection(self):
        status, detail = self.evaluate(harness=fuzz.driver([(1, 2)]))
        self.assertEqual(status, "runtime-failure")
        self.assertIn("result mismatch:", detail)

    def test_signal_is_not_success(self):
        status, detail = self.evaluate(harness="#include <signal.h>\nint main(void) { raise(SIGSEGV); }\n")
        self.assertEqual(status, "runtime-failure")
        self.assertIn("exit=-", detail)

    def test_execution_is_bounded(self):
        status, detail = self.evaluate(harness="int main(void) { for (;;) {} }\n")
        self.assertEqual(status, "timeout")
        executable = self.directory / "case/case.exe"
        self.assertTrue(executable.exists(), "control must reach native execution")
        self.assertEqual(detail, f"command timed out: ['{executable}']")

    def test_compile_timeout_cannot_satisfy_execution_control(self):
        with patch.object(self, "evaluate", return_value=("timeout", "command timed out: ['compiler']")):
            with self.assertRaises(AssertionError):
                self.test_execution_is_bounded()

    def test_rejection_is_logged(self):
        import random
        source, pairs = fuzz.generate(random.Random(646), "inclusive")
        status, detail = self.evaluate(source, fuzz.driver(pairs))
        self.assertEqual(status, "rejected")
        self.assertIn("refined int range mismatch", detail)
        self.assertTrue((self.directory / "case/compile.log").exists())

    def test_syntax_error_is_a_generator_failure(self):
        self.assertEqual(self.evaluate("invalid syntax;")[0], "generator-failure")

    def test_reduction_preserves_diagnosis(self):
        source = '''// Reduction must not turn a range violation into a wrong result.
extern fn fuzz_observe(value: i32, lo: i32, hi: i32);
fn fuzz_entry(x: i32) -> i32 {
    if (x >= 0 && x <= 2) { fuzz_observe(x, 0, 2); return x; }
    return -1;
}
'''
        harness = fuzz.driver([(-1, -1), (0, 0), (2, 2)])
        status, detail = self.evaluate(source, harness)
        self.assertEqual(status, "runtime-failure")
        self.assertIn("refinement violated:", detail)
        reduced = fuzz.minimize(self.compiler, source, harness,
                                self.directory / "reduction", 5, detail)
        status, detail = self.evaluate(reduced, harness)
        self.assertEqual(status, "runtime-failure")
        self.assertIn("refinement violated:", detail)
        self.assertLess(len(reduced), len(source))

    def test_zero_execution_cannot_pass(self):
        compiler = self.directory / "reject-all"
        compiler.write_text("#!/bin/sh\necho 'Error: rejects every input' >&2\nexit 1\n")
        compiler.chmod(0o755)
        result = subprocess.run([sys.executable, str(fuzz.ROOT / "scripts/fuzz_compiler.py"),
                                 "--compiler", str(compiler), "--cases", "7",
                                 "--output", str(self.directory / "empty")],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no accepted program was executed", result.stdout)


if __name__ == "__main__":
    unittest.main()
