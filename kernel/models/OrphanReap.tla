----------------------------- MODULE OrphanReap -----------------------------
EXTENDS Integers

(***************************************************************************)
(* Who collects an exited process once its parent cannot (GitHub issue     *)
(* #1310). A child and its parent exit independently, on different CPUs.   *)
(* A zombie is reapable only after the CPU that ran its exit has left its  *)
(* stack, so a parent exiting between the child's exit and that release    *)
(* cannot collect it, and nothing waits for the child afterwards.          *)
(*                                                                         *)
(* The rule is two checks that cannot both miss, both under the run lock:  *)
(* the hold that makes the parent Exited has just found no reapable zombie *)
(* (DRAIN_IN_HOLD), and the hold that releases the child's stack asks      *)
(* whether the parent is still Running (LEAVE_CHECKS_PARENT). The first    *)
(* covers a release before the parent's exit, the second one after it.     *)
(*                                                                         *)
(* DRAIN_IN_HOLD = FALSE is the kernel's drain before #1310: a last search *)
(* in a hold of its own, with a window before the parent's exit.           *)
(* LEAVE_CHECKS_PARENT = FALSE is the release asking nothing.              *)
(* Each strands the zombie: NoStranded.                                    *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    DRAIN_IN_HOLD,
    \* @type: Bool;
    LEAVE_CHECKS_PARENT

VARIABLES
    \* @type: Str;
    parent,     \* "Running" | "Exited" | "Gone" (reaped by its own parent)
    \* @type: Str;
    child,      \* "Running" | "Exited" | "Reaped"
    \* @type: Bool;
    stands,     \* a CPU still stands on the exited child's stack
    \* @type: Bool;
    deferred,   \* the releasing CPU has taken the reap on
    \* @type: Bool;
    drained     \* the unfixed drain has finished, in its own hold

vars == <<parent, child, stands, deferred, drained>>

Init ==
    /\ parent = "Running"
    /\ child = "Running"
    /\ stands = FALSE
    /\ deferred = FALSE
    /\ drained = FALSE

Reapable == child = "Exited" /\ ~stands

\* The child's exit: it is a zombie, and this CPU stands on its stack.
ChildExit ==
    /\ child = "Running"
    /\ child' = "Exited"
    /\ stands' = TRUE
    /\ UNCHANGED <<parent, deferred, drained>>

\* The hold that releases the child's stack.
ChildLeave ==
    /\ child = "Exited"
    /\ stands
    /\ stands' = FALSE
    /\ deferred' = (LEAVE_CHECKS_PARENT /\ parent # "Running")
    /\ UNCHANGED <<parent, child, drained>>

\* The releasing CPU reaps what it took on.
DeferredReap ==
    /\ deferred
    /\ child = "Exited"
    /\ child' = "Reaped"
    /\ deferred' = FALSE
    /\ UNCHANGED <<parent, stands, drained>>

\* The exiting parent's drain finds the zombie and reaps it.
ParentDrainReap ==
    /\ parent = "Running"
    /\ ~drained
    /\ Reapable
    /\ child' = "Reaped"
    /\ UNCHANGED <<parent, stands, deferred, drained>>

\* The fix: no zombie found, and Exited in that same hold.
ParentExitDrained ==
    /\ DRAIN_IN_HOLD
    /\ parent = "Running"
    /\ ~Reapable
    /\ parent' = "Exited"
    /\ UNCHANGED <<child, stands, deferred, drained>>

\* The unfixed drain's last search, in a hold of its own.
ParentDrainEnd ==
    /\ ~DRAIN_IN_HOLD
    /\ parent = "Running"
    /\ ~drained
    /\ ~Reapable
    /\ drained' = TRUE
    /\ UNCHANGED <<parent, child, stands, deferred>>

\* The unfixed exit, in a later hold, asking nothing.
ParentExit ==
    /\ ~DRAIN_IN_HOLD
    /\ parent = "Running"
    /\ drained
    /\ parent' = "Exited"
    /\ UNCHANGED <<child, stands, deferred, drained>>

\* The parent's own parent reaps it.
ParentReaped ==
    /\ parent = "Exited"
    /\ parent' = "Gone"
    /\ UNCHANGED <<child, stands, deferred, drained>>

\* Nothing left to happen.
Done ==
    /\ parent = "Gone"
    /\ child = "Reaped"
    /\ UNCHANGED vars

Next ==
    \/ ChildExit
    \/ ChildLeave
    \/ DeferredReap
    \/ ParentDrainReap
    \/ ParentExitDrained
    \/ ParentDrainEnd
    \/ ParentExit
    \/ ParentReaped
    \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ parent \in {"Running", "Exited", "Gone"}
    /\ child \in {"Running", "Exited", "Reaped"}
    /\ stands \in BOOLEAN
    /\ deferred \in BOOLEAN
    /\ drained \in BOOLEAN

\* A zombie its parent will never collect and no CPU has taken on.
NoStranded == ~(parent # "Running" /\ Reapable /\ ~deferred)

Safety == TypeOK /\ NoStranded

\* Every child ends up collected.
Collected == <>(child = "Reaped")

CInitFixed == DRAIN_IN_HOLD = TRUE /\ LEAVE_CHECKS_PARENT = TRUE
CInitSeparateHold == DRAIN_IN_HOLD = FALSE /\ LEAVE_CHECKS_PARENT = TRUE
CInitLeaveBlind == DRAIN_IN_HOLD = TRUE /\ LEAVE_CHECKS_PARENT = FALSE

=============================================================================
