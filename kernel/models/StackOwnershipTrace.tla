------------------------ MODULE StackOwnershipTrace ------------------------
(***************************************************************************)
(* Trace validation of StackOwnership.tla (GitHub issue #606, stage 2).    *)
(*                                                                         *)
(* /bin/protocol-trace opens a window in which the kernel diffs this      *)
(* model's state at every hold of the process-run lock                    *)
(* (kernel/kernel/protocol_trace.tkb) and prints the changes when the      *)
(* window closes. scripts/validate_protocol_trace.py turns the printed     *)
(* window into the module ProtocolTraceData -- one record per hold, with   *)
(* every process's state and stack owner and every core's current process  *)
(* and stood-on stack as they stand after that hold -- and asks TLC        *)
(* whether some behaviour of StackOwnership.tla produces exactly that      *)
(* sequence. The Python side only parses; no enabling condition or effect  *)
(* is written anywhere but StackOwnership.tla, so the check cannot drift   *)
(* from the model.                                                         *)
(*                                                                         *)
(* Observed: state, owner, current, stands. Not observed, and so chosen by *)
(* TLC among every value the model allows: reserved, interrupted and       *)
(* reapPending. Each locked hold that changes an observed variable is one  *)
(* step of the model; a hold that changes nothing observed is a stutter;   *)
(* an unlocked hold may change nothing observed at all (RecordLifetime's   *)
(* REMOVE_UNDER_LOCK, and every other change the model orders by the run   *)
(* lock). A record's allocation is ordered by the pool lock, not the run   *)
(* lock: a pid first seen Constructing is Constructing from the window's  *)
(* start, as the model's child is, which no invariant distinguishes.      *)
(*                                                                         *)
(* The trace is a behaviour of the model iff a state with l = Len(Trace)   *)
(* is reachable with every invariant intact. TLC reports exactly that as   *)
(* "Invariant TraceUnfinished is violated", and prints the matching        *)
(* behaviour, each step labelled with its action in `act`. If no behaviour *)
(* matches, TLC completes with no error, and the depth of its search is    *)
(* the last hold some behaviour reached.                                   *)
(*                                                                         *)
(* What a PASS claims is narrow: every protocol transition the kernel made *)
(* in this window is one the model has. It does not claim the model is     *)
(* right, and it says nothing about paths the window did not run.          *)
(***************************************************************************)

EXTENDS Naturals, Sequences, ProtocolTraceData

CONSTANTS
    EXIT_IDLES,
    LEAVE_CHECKS_STACK,
    WAKE_START_CHECKS_STACK,
    \* An action left out of the next-state relation, or "none": the
    \* negative control that a path the model lacked fails a passing run.
    WITHOUT,
    \* 0, or the index of a hold to stop at: a diagnostic run that has TLC
    \* print a behaviour reaching it, hidden variables included, after a
    \* refusal there.
    STOP_AT

VARIABLES
    state, current, reserved, stands, owner, interrupted, reapPending,
    l,      \* the index in Trace of the last hold taken in
    act     \* the model action the last step was, for the report

vars == <<state, current, reserved, stands, owner, interrupted, reapPending>>

\* TraceParent is each process's parent over the whole window: the link its
\* lines report. The model's ParentOf is a constant, so a window in which a
\* link changes (a reparented orphan) is refused before TLC runs; a link the
\* kernel clears while it removes the record is the same link.
Step == INSTANCE StackOwnership WITH
    Cores <- TraceCores, Procs <- TraceProcs, ParentOf <- TraceParent

None == Step!None
Idle == Step!Idle

----------------------------------------------------------------------------
(* The window opens with a snapshot taken under the run lock: no core has  *)
(* a reservation pending (the kernel opens only then, #681), no wake is    *)
(* pending, and a core whose current process runs while it stands on its   *)
(* idle stack is inside an interrupt taken from that process.             *)

Init ==
    /\ Trace[1].seq = 0
    /\ Trace[1].locked
    /\ l = 1
    /\ act = "snapshot"
    /\ state = Trace[1].state
    /\ owner = Trace[1].owner
    /\ current = Trace[1].current
    /\ stands = Trace[1].stands
    /\ reserved = [c \in TraceCores |-> None]
    /\ reapPending = [p \in TraceProcs |-> None]
    /\ interrupted = [c \in TraceCores |->
                        /\ Trace[1].current[c] # None
                        /\ Trace[1].stands[c] = Idle
                        /\ Trace[1].state[Trace[1].current[c]] = "Running"]

----------------------------------------------------------------------------

\* @type: (Str) => Bool;
Allowed(name) == WITHOUT # name

\* Every action of StackOwnership's Next, by name. Leaving one out here
\* only makes the check refuse more, never accept a step the model lacks:
\* each disjunct is the model's own action.
\* A reservation is taken by the core whose hold it is.
ModelStep(o) ==
    \/ Allowed("Wake") /\ act' = "Wake" /\ \E p \in TraceProcs : Step!Wake(p)
    \/ Allowed("Reserve") /\ act' = "Reserve"
       /\ \E p \in TraceProcs : Step!Reserve(o.cpu, p)
    \/ \E c \in TraceCores :
        \/ Allowed("CloneBegin") /\ act' = "CloneBegin"
           /\ \E q \in TraceProcs : Step!CloneBegin(c, q)
        \/ Allowed("CloneFinish") /\ act' = "CloneFinish" /\ Step!CloneFinish(c)
        \/ Allowed("CloneReschedule") /\ act' = "CloneReschedule"
           /\ Step!CloneReschedule(c)
        \/ Allowed("SwitchComplete") /\ act' = "SwitchComplete"
           /\ Step!SwitchComplete(c)
        \/ Allowed("Commit") /\ act' = "Commit" /\ Step!Commit(c)
        \/ Allowed("Wait4Block") /\ act' = "Wait4Block" /\ Step!Wait4Block(c)
        \/ Allowed("Nap") /\ act' = "Nap" /\ Step!Nap(c)
        \/ Allowed("ChildExit") /\ act' = "ChildExit" /\ Step!ChildExit(c)
        \/ Allowed("ChildExitStart") /\ act' = "ChildExitStart"
           /\ Step!ChildExitStart(c)
        \/ Allowed("IdleEnter") /\ act' = "IdleEnter" /\ Step!IdleEnter(c)
        \/ Allowed("Wait4Reap") /\ act' = "Wait4Reap"
           /\ \E q \in TraceProcs : Step!Wait4Reap(c, q)
        \/ Allowed("LeaveBegin") /\ act' = "LeaveBegin" /\ Step!LeaveBegin(c)
        \/ Allowed("LeaveComplete") /\ act' = "LeaveComplete"
           /\ Step!LeaveComplete(c)
        \/ Allowed("InterruptDepart") /\ act' = "InterruptDepart"
           /\ Step!InterruptDepart(c)
        \/ Allowed("TickLeave") /\ act' = "TickLeave" /\ Step!TickLeave(c)
        \/ Allowed("SwitchAway") /\ act' = "SwitchAway"
           /\ \E how \in {"Ready", "Napping", "Blocked"} : Step!SwitchAway(c, how)

\* The hold as the kernel reported it.
Observed(o) ==
    /\ state' = o.state
    /\ owner' = o.owner
    /\ current' = o.current
    /\ stands' = o.stands

Next ==
    /\ l < Len(Trace)
    /\ l' = l + 1
    /\ Observed(Trace[l + 1])
    /\ \/ UNCHANGED vars /\ act' = "none"
       \/ Trace[l + 1].locked /\ ModelStep(Trace[l + 1])

Spec == Init /\ [][Next]_<<vars, l, act>>

----------------------------------------------------------------------------
(* Invariants, checked after every hold. The first four are the model's;   *)
(* WaitMatchesState is the kernel wait cell's rule (#653), which the model *)
(* does not carry.                                                         *)

StackSafety == Step!StackSafety
RunningMatchesCores == Step!RunningMatchesCores
StartsOnFreeStack == Step!StartsOnFreeStack
NoLostWakeup == Step!NoLostWakeup

\* A Running process holds no published wait, except the wait4
\* continuation of a process reserved for a core and not yet current.
WaitMatchesState ==
    \A p \in TraceProcs :
        (state[p] = "Running" /\ Trace[l].reason[p] # 0) =>
            /\ Trace[l].reason[p] = 2
            /\ \E c \in TraceCores : reserved[c] = p

Invariants ==
    StackSafety /\ RunningMatchesCores /\ StartsOnFreeStack /\ NoLostWakeup
    /\ WaitMatchesState

NotStopped == l # STOP_AT

\* Violated exactly when the whole trace has been matched: the PASS.
TraceUnfinished == ~(l = Len(Trace) /\ Invariants)

=============================================================================
