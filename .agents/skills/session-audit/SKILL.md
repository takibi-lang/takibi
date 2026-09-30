---
name: session-audit
description: Light audit before a session ends -- unfinished requirements, documentation drift, classification of results, and ROADMAP.md upkeep. Use when the maintainer asks, and propose it yourself when the context is getting large or after several issues have closed in one session. Per-defect recurrence prevention is not repeated here; it belongs to defect-followup.
---

# Audit the session before it ends

Base every answer on the final `git diff` for the session's commits and on
the tests actually run.

1. **Completeness.** Are any requirements unfinished? Are there implicit
   assumptions, or missing boundary or failure cases?
2. **Documentation.** Does any Markdown file contradict the implementation?
3. **Recurrence prevention was done.** Confirm that `defect-followup` ran
   for every defect fixed this session. Run it now for any that was missed.
4. **Classify the results** as "fixed and verified", "left over from this
   session", or "deferred under YAGNI".
5. **ROADMAP.md.** Decide whether any of this belongs there. Remove closed
   issues from it, checking each with `gh issue view`.
6. **Land.** If anything is committed and not yet pushed, run `land`.

Report the result to the maintainer in the language of the conversation.
