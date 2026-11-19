# Design decision gate

Use this gate whenever a concrete design choice would otherwise cause a
pause, a worker reports needs decision, or an audit surfaces a new choice.
Apply it also when the coordinator works directly in single-task mode.

1. Read the issue and the active defaults and escalation conditions in
   DECISIONS.md. Name the choice, its constraints, and the viable options.
2. Always assess both A and B for each option.
   - A. Compile-time checking: name the invalid program or unsafe state,
     which rule rejects it, the coverage and trust boundary, and the
     annotation or migration cost. Identify dynamic checks and bounded
     model evidence at their actual assurance level.
   - B. Time and space: state compile and runtime costs, stack and
     retained memory where relevant. Mark each claim measured, derived,
     or unknown. State the workload and comparison baseline.
3. If A and B leave a material tradeoff or uncertainty, investigate both
   C and D before recommending a choice.
   - C. Compare the relevant Linux and BSD paths using primary sources.
     Explain which assumptions and costs carry over to Takibi.
   - D. Consult current research and modern language implementations
     using papers or official documentation. Identify usable mechanisms
     and the implementation or proof cost in Takibi.
   Record sources and any search that found no applicable precedent.
   When A and B are decisive, state why C and D were unnecessary.
4. Decide locally when one option is clearly preferable under the
   approved constraints: it preserves or strengthens the required checks
   and has no material time or space downside, or an existing maintainer
   decision already resolves the exact tradeoff. The evidence must cover
   the differences that could change the answer. Escalation conditions
   and explicit maintainer reservations still apply. Reversibility alone
   is insufficient. A worker may apply its existing delegated defaults;
   the coordinator resolves other locally decidable choices.
5. If the outcome is still material or uncertain, send one decision
   request with the options, A-D findings, recommendation, unresolved
   assumptions and what depends on the answer. In interactive mode stop
   at the prompt. During explicitly requested away mode use the single
   decision file for that period and continue eligible issues as specified
   in session.md. Independent work and authorized measurements can reduce
   uncertainty before requesting a decision.

Record a local choice on the issue and report it, with the decisive
evidence and applicable default. Do the same for the final maintainer
decision under github-workflow. This gate does not change the land gate
or confer approval for an explicit escalation.
