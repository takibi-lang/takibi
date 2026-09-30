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
   not possible, say why, and consider a build check. Do what is cheap now.
   File an issue, at the right grain, for what is realistic but larger and
   not already filed.
5. **Static or moved?** Did the fix exclude the problem statically, or move
   it into the trusted base, for example an `unsafe` block, a raw pointer,
   or a new liveness escape? Say which.
6. **Similar shapes.** Look at other call sites, the `kernel/` and
   `linux_user/` copies, and the corresponding compiler stage.
7. **Debugging aid.** Name a debugger feature or script that would have made
   this faster. Build it if it is cheap, or file it.

## Ask the maintainer

Whether to adopt a prevention measure is a design decision. Ask whenever one
is on the table; asking several times a day is expected. Missing a
recurrence-prevention chance costs more than a question. Ask in the language
of the conversation, in this shape: background (about three lines), options,
recommendation, and whether the choice can be undone later.

Record the answers on the defect's issue, or in the commit message if there
is no issue.
