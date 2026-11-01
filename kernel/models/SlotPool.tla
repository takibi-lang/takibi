----------------------------- MODULE SlotPool ------------------------------
EXTENDS Integers, Sequences

(***************************************************************************)
(* Scratch pools with more holders than cores (GitHub issue #993).         *)
(*                                                                         *)
(* One core runs one process at a time, and the tick may switch at any     *)
(* step, so four operations can each be holding something at once. Each    *)
(* pool has SLOTS slots, fewer than the operations: one, because a cycle   *)
(* only needs every slot held and the kernel's four are the same shape     *)
(* with four times the operations. An acquire that finds                   *)
(* every slot held retries with interrupts unmasked, so its wait is a      *)
(* tick's switch to someone else, not a sleep; the first failed pass is    *)
(* counted (slot_pool_wait_note).                                          *)
(*                                                                         *)
(* An operation walks a fixed list of resources, then gives them all back: *)
(* "M" the ext2 mutation lock, "Q" a mutator's wait for ext2's readers to  *)
(* reach zero, "R" a reader's count (refused while M is held, and then the *)
(* syscall reruns, holding nothing), and the pools "S" SyscallSlot, "E"    *)
(* Ext2Slot and "B" BlockSlot.                                             *)
(*                                                                         *)
(* ORDER = "fixed" is the kernel: M before S, as #993 made an ext2 write   *)
(* do. "slotfirst" is the tree before it: a write takes S, then M, while   *)
(* mkdir takes M, then S. A writer holding the slots waits for mkdir's     *)
(* lock and mkdir waits for a slot. "allslotfirst" is the other cure,      *)
(* every mutator S then M; it still deadlocks, through the reader count:   *)
(* a mutator holding M waits for a reader, the reader waits for a slot,    *)
(* and the slots are held by mutators waiting for M. "innerouter" is the   *)
(* failing control the issue asks for, a holder of the inner pool taking   *)
(* the outer one. UNMASKED = FALSE is a retry with interrupts masked: the  *)
(* tick cannot switch a spinner away, it keeps the core its holder needs,  *)
(* and the fixed order alone does not end the wait.                        *)
(*                                                                         *)
(* kernel/models/README.md maps each action to the functions it abstracts. *)
(***************************************************************************)

CONSTANTS
    \* @type: Str;
    ORDER,
    \* @type: Bool;
    UNMASKED

Procs == {"a", "b", "c", "d"}
SLOTS == 1
Pools == {"S", "E", "B"}

VARIABLES
    \* @type: Str -> Int;
    pc,          \* how many steps of its list each operation has done
    \* @type: Str -> Bool;
    finished,    \* gave everything back
    \* @type: Str -> Int;
    used,        \* slots held, per pool
    \* @type: Str;
    mutator,     \* who holds M, or "none"
    \* @type: Int;
    readers,     \* ext2_readers
    \* @type: Str -> Bool;
    waited,      \* this operation's acquire has been counted
    \* @type: Str;
    cur          \* the process the one core runs

vars == <<pc, finished, used, mutator, readers, waited, cur>>

\* @type: Seq(Str);
Mutate == <<"M", "Q", "S", "E", "B">>
\* @type: Seq(Str);
SlotThenMutate == <<"S", "M", "Q", "E", "B">>
\* @type: Seq(Str);
Read == <<"R", "S", "E", "B">>

\* @type: Seq(Str);
InnerFirst == <<"E", "S">>
\* @type: Seq(Str);
OuterFirst == <<"S", "E">>

\* @type: (Str) => Seq(Str);
Steps(p) ==
    IF ORDER = "fixed" THEN
        IF p \in {"a", "b"} THEN Mutate ELSE Read
    ELSE IF ORDER = "slotfirst" THEN
        IF p \in {"a", "b"} THEN SlotThenMutate
        ELSE IF p = "c" THEN Mutate ELSE Read
    ELSE IF ORDER = "allslotfirst" THEN
        IF p \in {"a", "b", "c"} THEN SlotThenMutate ELSE Read
    ELSE
        IF p \in {"a", "b"} THEN OuterFirst ELSE InnerFirst

\* @type: (Str) => Bool;
AtEnd(p) == pc[p] = Len(Steps(p))

\* @type: (Str) => Str;
Wants(p) == Steps(p)[pc[p] + 1]

\* @type: (Str) => Bool;
HoldsCount(p) == \E i \in 1..5 : i <= pc[p] /\ Steps(p)[i] = "R"

\* What the next step needs is there.
\* @type: (Str) => Bool;
CanStep(p) ==
    /\ ~finished[p]
    /\ ~AtEnd(p)
    /\ LET r == Wants(p) IN
         IF r = "M" THEN mutator = "none"
         ELSE IF r = "Q" THEN readers = 0
         ELSE IF r = "R" THEN mutator = "none"
         ELSE used[r] < SLOTS

\* syscall_slot_acquire, ext2_slot_acquire, block_slot_acquire: one
\* successful compare-exchange; ext2_mutation_take's lock and its wait for
\* the readers; ext2_read_enter's count.
\* @type: (Str) => Bool;
Step(p) ==
    /\ cur = p
    /\ CanStep(p)
    /\ LET r == Wants(p) IN
         /\ used' = IF r \in Pools THEN [used EXCEPT ![r] = @ + 1] ELSE used
         /\ mutator' = IF r = "M" THEN p ELSE mutator
         /\ readers' = IF r = "R" THEN readers + 1 ELSE readers
    /\ pc' = [pc EXCEPT ![p] = @ + 1]
    /\ waited' = [waited EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<finished, cur>>

\* A full pass over a pool's words: slot_pool_wait_note, once per acquire.
\* The retry that follows is this process still running, which is no state.
\* @type: (Str) => Bool;
FullPass(p) ==
    /\ cur = p
    /\ ~finished[p]
    /\ ~AtEnd(p)
    /\ Wants(p) \in Pools
    /\ used[Wants(p)] = SLOTS
    /\ ~waited[p]
    /\ waited' = [waited EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<pc, finished, used, mutator, readers, cur>>

\* The releases at the end of the operation: ext2_slot_release and the rest,
\* ext2_mutation_give, ext2_read_leave. Each only frees, so together is safe.
\* @type: (Str) => Bool;
Finish(p) ==
    /\ cur = p
    /\ ~finished[p]
    /\ AtEnd(p)
    /\ finished' = [finished EXCEPT ![p] = TRUE]
    /\ used' = [r \in Pools |->
                  IF \E i \in 1..5 : i <= pc[p] /\ Steps(p)[i] = r
                    THEN used[r] - 1 ELSE used[r]]
    /\ mutator' = IF mutator = p THEN "none" ELSE mutator
    /\ readers' = IF HoldsCount(p) THEN readers - 1 ELSE readers
    /\ UNCHANGED <<pc, waited, cur>>

\* @type: (Str) => Bool;
Spinning(p) ==
    IF finished[p] \/ AtEnd(p) THEN FALSE
    ELSE IF Wants(p) \in Pools THEN used[Wants(p)] = SLOTS ELSE FALSE

\* The tick at IRQ return: the next process, whatever this one was doing.
\* Without UNMASKED a process retrying a full pool does not take the tick.
Switch ==
    /\ UNMASKED \/ ~Spinning(cur)
    /\ \E p \in Procs : ~finished[p]
    /\ cur' = CASE cur = "a" -> "b"
                [] cur = "b" -> "c"
                [] cur = "c" -> "d"
                [] OTHER -> "a"
    /\ UNCHANGED <<pc, finished, used, mutator, readers, waited>>

AllFinished == \A p \in Procs : finished[p]

Done ==
    /\ AllFinished
    /\ UNCHANGED vars

Init ==
    /\ pc = [p \in Procs |-> 0]
    /\ finished = [p \in Procs |-> FALSE]
    /\ used = [r \in Pools |-> 0]
    /\ mutator = "none"
    /\ readers = 0
    /\ waited = [p \in Procs |-> FALSE]
    /\ cur = "a"

Next ==
    \/ \E p \in Procs : Step(p) \/ FullPass(p) \/ Finish(p)
    \/ Switch
    \/ Done

Fairness ==
    /\ WF_vars(Switch)
    /\ \A p \in Procs : SF_vars(Step(p)) /\ SF_vars(Finish(p)) /\ SF_vars(FullPass(p))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A p \in Procs : pc[p] \in 0..5
    /\ \A r \in Pools : used[r] \in 0..SLOTS
    /\ mutator \in Procs \cup {"none"}
    /\ readers \in 0..4
    /\ cur \in Procs

\* Someone can always move: the wait-for graph has no cycle. A full pass is
\* not a move, and neither is the switch; whose turn it is does not matter.
NoDeadlock ==
    \/ AllFinished
    \/ \E p \in Procs : CanStep(p) \/ (~finished[p] /\ AtEnd(p))

\* Every acquire ends, because every operation does.
EveryAcquireEnds == <>AllFinished

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == ORDER = "fixed" /\ UNMASKED = TRUE
CInitSlotFirst == ORDER = "slotfirst" /\ UNMASKED = TRUE
CInitAllSlotFirst == ORDER = "allslotfirst" /\ UNMASKED = TRUE
CInitInnerOuter == ORDER = "innerouter" /\ UNMASKED = TRUE
CInitMasked == ORDER = "fixed" /\ UNMASKED = FALSE

=============================================================================
