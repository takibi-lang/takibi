# Takibi roadmap

The current work split, and nothing else. It is rewritten when priorities
move and is expected to go stale. Findings belong on the GitHub issue they
concern, reasoning and past events in `HISTORY.md`, current behavior in
`kernel/README.md`. Do not add an investigation record here: this file is for
who does what next. The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Territories, re-cut 2026-09-23

A territory is a role, not a set of directories and not a particular agent
(`AGENTS.md`); which agent holds which is the maintainer's per-session
decision. Territory A's route is inherently single-task -- each step needs the
previous one's four-core RPi5 evidence -- so A takes it alone, and every issue
off that route belongs to B even where that risks a merge conflict. The
maintainer rebases and merges often, which is what prevents double
implementation. If a B issue blocks a step of A's route, A pulls it and says
so on the issue. Compiler work a step of A needs is done in A as part of that
step, landed as its own commit.

### Territory A: the multicore route, in this order

1. **True multicore support**: every online core runs ordinary processes,
   any core can issue any syscall, and a process can continue on another
   core. #9, #591 (dynamic exec, which #581's test needs), #581 (network
   admission remains), #582, #583, #589; and the
   multicore-correctness issues #570, #559, #550, #560, #482, #464, #468,
   #556, #573.
2. **Run the multicore workload mainly on RPi5 and fix what it finds.** #584
   is the workload, #572 its fairness verdict. Each defect it finds gets a
   deterministic lane before its issue closes.
3. **Takibi's provisional answer to safe pointers and safe memory access,
   with multicore as a premise.** #343, #342, #202, #518, #131, #132, #370,
   #216.
4. **Begin evaluating recent research**: typestate, the K framework,
   invariants, partial TLA+. First consumers #590, #308 and #109; proof-side entry
   #13. An evaluation, not a decision to adopt.

### Territory B: everything else, ordered by current priority

1. **Concrete correctness and evidence gaps:** #274, #551, #542, #388.
2. **Kernel and userspace capability:** #432, #436, #535, #537, #539, #536,
   #171, #204, #433, #430, #434, #435, #220.
3. **Resource use and measured performance:** #389, #422, #497, #520, #553,
   #386, #502, #503.
4. **Compiler safety and language research:** #58, #203, #252, #200, #201,
   #282, #129, #374, #417, #155, #28, #8.
5. **Toolchain, portability and hardware-lane support:** #576, #568, #123,
   #124, #122, #95, #51, #50, #85, #268.
6. **Deferred or not a scheduled work item:** #555, #250, #444, #429, #149,
   #567.

Items are ordered within each band as well as between bands. The deferred
items stay listed so a changed premise can bring them back into the queue.
