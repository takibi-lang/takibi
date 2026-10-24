#!/usr/bin/env python3
"""Controls for check_proof_fold_width.py (GitHub issues #956, #961, #983)."""

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_proof_fold_width.py"
CASES = CaseCount()


def load():
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location(
        "check_proof_fold_width", CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(checker, files=None):
    CASES.note()
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        status = checker.main(files)
    return status, output.getvalue()


# The Band rule as #952 left it: the mask folded natively, so
# `x & (0xFFFFFFFFFFFFFFFF / 64)` on u64 proved {0..<1}.
PRE_956_BAND = """\
           (match intlit_opt e2 with
            | Some k when k >= 0 -> refined_or_base ct1 (Some 0) (checked_add k 1)
            | _ -> ct1)
let intlit_opt (e : Ast.expr) : int option =
  Const_env.folded_value e
"""

FIXED_BAND = """\
           (match fold_at_ty ct1 e2 with
            | Some k when k >= 0 -> refined_or_base ct1 (Some 0) (checked_add k 1)
            | _ -> ct1)
"""

EXEMPT_REJECTION = """\
           (* fold-not-proof: a rejection, not a proof. *)
           (match Const_env.folded_value e2 with
            | Some 0 -> raise (TypeError (e2.loc, "division by zero"))
            | _ -> ());
"""

EXEMPT_TOO_FAR = """\
           (* fold-not-proof: a rejection, not a proof. *)
           let a = 1 in
           let b = 2 in
           let c = 3 in
           let d = 4 in
           (match Const_env.folded_value e2 with
            | _ -> ());
"""

COMMENT_ONLY = """\
  (* used to read Const_env.folded_value e here *)
  fold_at_ty t e
"""

WIDTH_AWARE = """\
  Const_env.folded_value_within lo hi e
"""

SPACED = """\
  Const_env . folded_value e
"""

# The unannotated for-loop bound as #956 left it: 0xFFFFFFFFFFFFFFFF read
# as -1 gave a u64 counter {0..<-1} (#961).
PRE_961_FOR = """\
        | None -> (Const_env.bound_value lo_expr, Const_env.bound_value hi_expr)
"""

FIXED_FOR = """\
        | None -> (bound_at_base base lo_expr, bound_at_base ~bound:true base hi_expr)
"""

# init_flow's linear term leaf as #983 found it: 0xFFFFFFFFFFFFFFFF read
# as -1, so a callee's [n, 8) covered [0, 8) in the caller.
PRE_983_LEAF = """\
    | Ast.IntLit n -> Option.map Init_pred.const (Ast.int_of_intlit n)
"""

PRE_983_CONST = """\
         | None -> Option.map Init_pred.const (Const_env.find x))
"""

FIXED_983 = """\
    | Ast.IntLit n -> leaf_const (Ast.int_of_intlit n)
         | None -> leaf_const (Const_env.find x))
"""


def main() -> int:
    checker = load()
    status, output = run(checker)
    if status != 0 or "PASS proof-fold-width" not in output:
        print(f"FAIL proof-fold-width control: the repository failed\n{output}")
        return 1

    cases = [
        ("the fixed Band rule", FIXED_BAND, 0, "PASS proof-fold-width"),
        ("the pre-#956 native fold behind intlit_opt", PRE_956_BAND, 1,
         "raw Const_env.folded_value"),
        ("a rejection exempted by a fold-not-proof comment",
         EXEMPT_REJECTION, 0, "PASS proof-fold-width"),
        ("an exemption five lines above", EXEMPT_TOO_FAR, 1,
         "raw Const_env.folded_value"),
        ("a raw fold named only in a comment", COMMENT_ONLY, 0,
         "PASS proof-fold-width"),
        ("the width-aware fold", WIDTH_AWARE, 0, "PASS proof-fold-width"),
        ("a raw fold spelled with spaces", SPACED, 1,
         "raw Const_env.folded_value"),
        ("the pre-#961 native for-loop bound", PRE_961_FOR, 1,
         "raw Const_env.bound_value"),
        ("the width-aware for-loop bound", FIXED_FOR, 0,
         "PASS proof-fold-width"),
        ("the pre-#983 native literal leaf", PRE_983_LEAF, 1,
         "raw Ast.int_of_intlit"),
        ("the pre-#983 native constant leaf in init_flow.ml", PRE_983_CONST,
         1, "raw Const_env.find", "init_flow.ml"),
        ("a Const_env.find outside init_flow.ml", PRE_983_CONST, 0,
         "PASS proof-fold-width"),
        ("the #983 leaves through leaf_const", FIXED_983, 0,
         "PASS proof-fold-width", "init_flow.ml"),
    ]
    with tempfile.TemporaryDirectory() as name:
        for index, (label, text, expected, needle, *file) in enumerate(cases):
            folder = Path(name) / f"case{index}"
            folder.mkdir()
            path = folder / (file[0] if file else f"case{index}.ml")
            path.write_text(text, encoding="ascii")
            status, output = run(checker, [path])
            if status != expected or needle not in output:
                print(f"FAIL proof-fold-width control: {label} exited "
                      f"{status} (expected {expected}) without {needle!r}\n"
                      f"{output}")
                return 1

    report_pass("proof-fold-width-controls",
                "the repository passes; the pre-#956 native fold, the "
                "pre-#961 native bound, the pre-#983 literal and constant "
                "leaves, an "
                "exemption out of reach and a spaced spelling are refused; "
                "an exempted rejection, a comment and the width-aware fold "
                "and bound "
                "are not",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
