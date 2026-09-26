---------------------------- MODULE Wait4Block ----------------------------
(***************************************************************************)
(* The wait4 ChildExit window (GitHub issue #550), the first slice of the  *)
(* #601 scheduler model.                                                   *)
(*                                                                         *)
(* A parent calls wait4 for its only child. The kernel decides "the child  *)
(* has not exited, so block" in one critical section, and publishes the    *)
(* parent Blocked in a LATER one. If the child exits between the two, its  *)
(* exit finds the parent still Running and wakes nobody; the parent then   *)
(* sleeps with a zombie child that will never wake it.                     *)
(*                                                                         *)
(* RECHECK = FALSE is the kernel as it is: nothing looks at the child     *)
(* again when Blocked is published. TLC must find NoLostWakeup violated.  *)
(* RECHECK = TRUE is the proposed fix: the publication re-checks the       *)
(* child under the same lock, and reruns wait4 if it has exited.          *)
(*                                                                         *)
(* Each action is ONE critical section under the process-run lock in the  *)
(* kernel -- an action is atomic here exactly because it is atomic there.  *)
(* kernel/models/README.md maps every action to the function it abstracts. *)
(*                                                                         *)
(* Type annotations (the `@type:` comments) are for Apalache; TLC ignores  *)
(* them. scripts/run_model_checks.sh checks them on every run.             *)
(***************************************************************************)

CONSTANT
    \* @type: Bool;
    RECHECK

\* Two cores, and three processes: the waiting parent, its child, and one
\* other runnable process. The other one matters: wait4 only takes the
\* Block path when there is a successor to switch to.
Cores == {"c0", "c1"}
Procs == {"parent", "child", "other"}
None == "none"

VARIABLES
    \* @type: Str -> Str;
    state,      \* per process: "Ready" | "Running" | "Blocked" | "Exited" | "Reaped"
    \* @type: Str -> Str;
    current,    \* per core: the process it runs, or None when idle
    \* @type: Str;
    wait        \* the parent's wait4: "call" | "decided" | "asleep" | "woken" | "done"

vars == <<state, current, wait>>

----------------------------------------------------------------------------
(* Helpers *)

\* @type: (Str, Str) => Bool;
RunsOn(p, c) == current[c] = p

\* The parent is in the middle of its wait4 syscall once it has decided;
\* the kernel is not preemptible there (KERNEL_PREEMPTIBLE = 0).
\* @type: (Str) => Bool;
Preemptible(p) == p # "parent" \/ wait \in {"call", "done"}

----------------------------------------------------------------------------
(* Initial state: parent and child running, the other process Ready. *)

Init ==
    /\ state = [p \in Procs |->
                    IF p = "other" THEN "Ready" ELSE "Running"]
    /\ current = [c \in Cores |->
                    IF c = "c0" THEN "parent" ELSE "child"]
    /\ wait = "call"

----------------------------------------------------------------------------
(* Actions *)

\* wait4's decision. A zombie child is reaped at once; otherwise the
\* parent records that it will block, and is still Running.
Wait4Decide ==
    /\ \E c \in Cores : RunsOn("parent", c)
    /\ wait = "call"
    /\ IF state["child"] = "Exited"
         THEN /\ state' = [state EXCEPT !["child"] = "Reaped"]
              /\ wait' = "done"
         ELSE /\ wait' = "decided"
              /\ UNCHANGED state
    /\ UNCHANGED current

\* Publishing Blocked, and switching this core to a Ready successor --
\* any Ready process, as kernel_process_next_ready picks one -- or, with
\* none, leaving it idle (kernel_process_block_to_idle, open to ChildExit
\* since #550). With RECHECK, an exited child cancels the block and wait4
\* reruns.
Wait4Block ==
    \E c \in Cores :
        /\ RunsOn("parent", c)
        /\ wait = "decided"
        /\ IF RECHECK /\ state["child"] = "Exited"
             THEN /\ wait' = "call"
                  /\ UNCHANGED <<state, current>>
           ELSE IF \E q \in Procs : state[q] = "Ready"
             THEN \E q \in Procs :
                     /\ state[q] = "Ready"
                     /\ state' = [state EXCEPT !["parent"] = "Blocked",
                                                ![q] = "Running"]
                     /\ current' = [current EXCEPT ![c] = q]
                     /\ wait' = "asleep"
             ELSE /\ state' = [state EXCEPT !["parent"] = "Blocked"]
                  /\ current' = [current EXCEPT ![c] = None]
                  /\ wait' = "asleep"

\* The child exits. It wakes the parent only if the parent is already
\* Blocked in wait4; the core it ran on goes idle.
ChildExit ==
    \E c \in Cores :
        /\ RunsOn("child", c)
        /\ LET wakes == state["parent"] = "Blocked" /\ wait = "asleep"
           IN  /\ state' = [state EXCEPT
                              !["child"] = "Exited",
                              !["parent"] = IF wakes THEN "Ready" ELSE @]
               /\ wait' = IF wakes THEN "woken" ELSE wait
        /\ current' = [current EXCEPT ![c] = None]

\* A woken parent runs again and finishes wait4 by reaping the zombie.
Wait4Resume ==
    /\ \E c \in Cores : RunsOn("parent", c)
    /\ wait = "woken"
    /\ state' = [state EXCEPT !["child"] = "Reaped"]
    /\ wait' = "done"
    /\ UNCHANGED current

\* The timer takes a Running process off its core.
Preempt(c) ==
    /\ current[c] # None
    /\ Preemptible(current[c])
    /\ state' = [state EXCEPT ![current[c]] = "Ready"]
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED wait

\* An idle core takes a Ready process.
\* @type: (Str, Str) => Bool;
Dispatch(c, p) ==
    /\ current[c] = None
    /\ state[p] = "Ready"
    /\ state' = [state EXCEPT ![p] = "Running"]
    /\ current' = [current EXCEPT ![c] = p]
    /\ UNCHANGED wait

Next ==
    \/ Wait4Decide
    \/ Wait4Block
    \/ ChildExit
    \/ Wait4Resume
    \/ \E c \in Cores : Preempt(c)
    \/ \E c \in Cores, p \in Procs : Dispatch(c, p)

\* Fairness, the scheduler's promises this model relies on:
\* - a Ready process is eventually put on some core. The kernel's rotation
\*   (kernel_process_next_ready) visits every live process, so no Ready
\*   process is passed over forever. Without this, TLC finds a behaviour
\*   where idle cores keep choosing "other" and the parent never runs,
\*   which is a weakness of the model's scheduler, not of wait4.
\* - the parent and child keep getting to run their steps even though the
\*   timer may take them off a core in between (strong fairness).
Fairness ==
    /\ \A p \in Procs : SF_vars(\E c \in Cores : Dispatch(c, p))
    /\ SF_vars(Wait4Decide)
    /\ SF_vars(Wait4Block)
    /\ SF_vars(ChildExit)
    /\ SF_vars(Wait4Resume)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A p \in Procs :
           state[p] \in {"Ready", "Running", "Blocked", "Exited", "Reaped"}
    /\ \A c \in Cores : current[c] \in Procs \union {None}
    /\ wait \in {"call", "decided", "asleep", "woken", "done"}

\* A process is Running exactly when some core runs it, and no process
\* runs on two cores.
RunningMatchesCores ==
    /\ \A p \in Procs :
           (state[p] = "Running") <=> (\E c \in Cores : RunsOn(p, c))
    /\ \A c, d \in Cores :
           (c # d /\ current[c] # None) => current[c] # current[d]

\* #550, as a safety property: the parent is never asleep in wait4 while
\* its child is already a zombie. Nothing would wake it.
NoLostWakeup ==
    ~(state["parent"] = "Blocked" /\ state["child"] = "Exited")

\* #550, as the liveness property #601 asks for: wait4 finishes.
Wait4Finishes == <>(wait = "done")

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == RECHECK = TRUE
CInitUnfixed == RECHECK = FALSE

=============================================================================
