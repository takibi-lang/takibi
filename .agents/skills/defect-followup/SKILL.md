---
name: defect-followup
description: Recurrence prevention for one defect, done right after it is fixed and before the fix is landed -- root cause, why tests missed it, the cheapest faithful regression test, whether a model check, the compiler, or a build check could prevent the class, and whether similar shapes remain. Use every time a bug is fixed, including bugs found by a red allcheck.
---

# Follow up one fixed defect

Recurrence prevention is most valuable while the defect is fresh, so it is
done per defect, now, not collected for the end of the session. Base every
answer on the diff and the tests actually run.

## Questions

1. **Root cause.** What was actually wrong, in one paragraph.
2. **Why the existing tests missed it.**
3. **The cheapest faithful regression test.** It must fail on the old code.
   Use `add-takibi-test` to choose where it lives. Add it now.
4. **Prevention of the class**, in the order the "Lightweight by design"
   rule in AGENTS.md prefers: a type the checker infers or one signature
   carries, an indexed owner or view at an API boundary, a bounded model
   check tied to the code, a build-time check. If a compile-time error is
   not possible, say why, and consider an external check. Classify each
   prevention using the placement policy below before implementing it;
   cheap initial implementation alone does not justify a new script.
   File an issue, at the right grain, for what is realistic but larger and
   not already filed.
5. **Static or moved?** Did the fix exclude the problem statically, or move
   it into the trusted base, for example an `unsafe` block, a raw pointer,
   or a new liveness escape? Say which.
6. **Similar shapes.** Look at other call sites, the `kernel/` and
   `linux_user/` copies, and the corresponding compiler stage.
7. **Debugging aid.** Name a debugger feature or script that would have made
   this faster. Build it if it is cheap, or file it.
8. **Solver or proof assistant.** Would an SMT check (Z3 over bit-vector or
   linear-integer obligations) have caught it? If yes, add a comment on #952
   with the defect, the obligation and the issue. Would a proof assistant
   (Lean/Rocq) have prevented it, and at which level: a compiler rule proved
   once, or a property of the .tkb program? If yes, add a comment on #955
   with the defect, the level, what would have been proved, and a rough proof
   size. Say "no" with the reason otherwise. Record only; do not implement.
9. **Rust baseline.** Would the Rust toolchain as a kernel uses it have
   caught the defect, and by what: safe Rust's type system (R-type), a
   run-time panic only when the path executes (R-panic), a lint outside
   rustc such as klint or clippy (R-lint), a bounded or execution-based
   tool that explores a limited set of runs such as Kani or Miri
   (R-bounded), a deductive verifier that proves all runs from written
   pre/postconditions and invariants such as Verus or Flux (R-deductive;
   name in one line the specification it would have needed), nothing
   (R-none, naming the Takibi rule or token that does), or not applicable
   because the defect is in Takibi's own compiler or tooling (N/A)? Add one
   row to the log on #1043 with the verdict and one line of reasoning; an
   uncertain verdict says so in its Notes cell. Record only; do not
   implement.
10. **Formal method that would have found the missing fact.** Beyond a
   solver re-check or a proof: which annotation-free technique on the
   proposer ladder of #1456 would have inferred the invariant or contract
   the defect lacked -- a checked `noreturn` on a function, a Houdini
   candidate over a loop's versioned locals, interval or linear abstract
   interpretation with widening, a CHC/Spacer-proposed inductive invariant,
   or none (say why: a quantifier, a nonlinear term, a heap shape, a
   protocol property)? Also say whether the defect is a case for a
   technique the 2026-11-08 table on #13 did not adopt (bi-abduction,
   termination analysis, dynamic invariant detection); that is the evidence
   that reopens the row. Add one comment on #1456 with the defect, the rung
   and the invariant in one line. Record only; do not implement.

## Prevention placement policy

Classify each responsibility, not the defect or the whole tool. First use
existing types, ownership, effects or API boundaries to make the bad program
unrepresentable. Keep a faithful regression test even when static prevention
is adopted; placement and test tier are separate decisions.

Choose by the facts needed and who should enforce the rule:

1. **OCaml, integrated into the Takibi compiler.** The rule judges whether a
   Takibi program may compile, using its syntax or semantics. Prefer a
   general type, ownership or effect rule over a relocated per-site table.
   A kernel-specific policy may instead be an explicit compiler option in
   a separate module; distinguish that policy from type-system soundness.
2. **OCaml, a standalone tool.** The check needs Takibi syntax or semantics,
   but enforces repository conventions or correspondence with external
   artifacts rather than program acceptance. Reuse the compiler's parser,
   AST, name resolution or typed facts as needed. Examples are cross-platform
   implementation comparisons and source-to-model correspondence. Do not
   create a second lexer, parser or semantic analysis, even for an initially
   small check. Reuse the narrowest existing interface; do not build a
   speculative general analysis platform.
3. **Python, maintained independently of the compiler.** The check acquires
   or compares external facts without interpreting Takibi syntax or
   semantics: QEMU/PTY/board orchestration, output verdicts, timing or ELF
   layout. Reading compiler-emitted facts for a comparison is allowed;
   rebuilding name resolution or semantic analysis over an exported AST
   belongs in category 2. External does not mean run-time only.

A prevention can combine these categories. For each new or substantially
changed check, record its category, the facts it needs, and why that owner
is appropriate on the defect's issue or in the commit message. For category
3, name the external fact that needs checking. If an independent check grows
Takibi-language analysis, reconsider its placement before extending it.

This is not a default language for disposable scripts, a requirement to
rewrite all existing Python, or authorization for compiler work outside the
current scope. A larger compiler capability still needs the maintainer's
design decision. If it cannot be done in the current slice, record the gap
and agree the interim measure rather than automatically growing a Python
source scanner. Count maintenance and duplicated analysis in the cost, not
just the time to write the first check. Preserve the prevention ladder and
state bounded model evidence at its actual strength.

## Ask the maintainer

Whether to adopt a prevention measure is a design decision. Ask whenever one
is on the table; asking several times a day is expected. Missing a
recurrence-prevention chance costs more than a question. Ask in the language
of the conversation, in this shape: background (about three lines), options,
recommendation, and whether the choice can be undone later.

Record the answers on the defect's issue, or in the commit message if there
is no issue.
