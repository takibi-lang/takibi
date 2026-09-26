-------------------------- MODULE StackOwnership --------------------------
(***************************************************************************)
(* Kernel stack ownership across switches, exits and idle entry (GitHub    *)
(* issue #601, second model).                                              *)
(*                                                                         *)
(* A core's LOGICAL current process and the stack it PHYSICALLY stands on  *)
(* are different things here, as they are in the kernel: after a switch    *)
(* the core still stands on the outgoing process's stack until the        *)
(* exception return completes (kernel_process_stack_switch_complete), and *)
(* after an exit it stands on the zombie's stack until it moves to its    *)
(* idle stack. `owner` is each process stack's physical owner.            *)
(*                                                                         *)
(* Two past defects are variants, each re-introduced by one constant:      *)
(*                                                                         *)
(* EXIT_IDLES = FALSE -- 08df64c6's deadlock. After an exit, core 0 waited *)
(*   for a successor while still standing on the zombie's stack. The only *)
(*   successor was the parent, Ready with its wait4 continuation, which   *)
(*   may not start while the child's stack is owned. TLC reports a        *)
(*   deadlock.                                                             *)
(*                                                                         *)
(* LEAVE_CHECKS_STACK = FALSE -- 765a27af's lost child. A process leaving  *)
(*   its core (an excluded process at a syscall return, a Migrate) hands  *)
(*   back whatever stack the core stands on. A clone child's first return *)
(*   still stands on its PARENT's stack, so leaving there made the parent *)
(*   Ready and lost the child. TLC reports RunningMatchesCores violated.  *)
(*                                                                         *)
(* Each action is one kernel critical section under the process-run lock. *)
(* kernel/models/README.md maps each action to the function it abstracts. *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    EXIT_IDLES,
    \* @type: Bool;
    LEAVE_CHECKS_STACK

Cores == {"c0", "c1"}
Procs == {"parent", "child"}
None == "none"
Idle == "idle"      \* the core's own idle stack, owned by nobody else

VARIABLES
    \* @type: Str -> Str;
    state,      \* per process: "Unborn" | "Ready" | "Running" | "Blocked" | "Exited" | "Reaped"
    \* @type: Str -> Str;
    current,    \* per core: its logical current process, or None
    \* @type: Str -> Str;
    stands,     \* per core: the process whose stack it stands on, or Idle
    \* @type: Str -> Str;
    owner,      \* per process: the core owning its stack, or None
    \* @type: Bool;
    reapPending \* the parent was woken in wait4 and still has to reap the child

vars == <<state, current, stands, owner, reapPending>>

----------------------------------------------------------------------------
(* Helpers *)

\* The core runs p on p's own stack: the physical switch has completed.
\* @type: (Str, Str) => Bool;
Settled(c, p) == current[c] = p /\ stands[c] = p

\* scheduled_process_ready_take: a Ready process may be started only once no
\* core owns its stack -- and a parent carrying a wait4 continuation only once
\* no core owns the exited child's stack either.
\* @type: (Str) => Bool;
Takeable(p) ==
    /\ state[p] = "Ready"
    /\ owner[p] = None
    /\ (p = "parent" /\ reapPending) => owner["child"] = None

----------------------------------------------------------------------------
(* Initial state: the parent runs on c0; c1 idles. *)

Init ==
    /\ state = [p \in Procs |-> IF p = "parent" THEN "Running" ELSE "Unborn"]
    /\ current = [c \in Cores |-> IF c = "c0" THEN "parent" ELSE None]
    /\ stands = [c \in Cores |-> IF c = "c0" THEN "parent" ELSE Idle]
    /\ owner = [p \in Procs |-> IF p = "parent" THEN "c0" ELSE None]
    /\ reapPending = FALSE

----------------------------------------------------------------------------
(* Actions *)

\* clone: the child's first return runs first. The core's current process
\* becomes the child while it still stands on the parent's stack.
Clone(c) ==
    /\ Settled(c, "parent")
    /\ state["child"] = "Unborn"
    /\ state' = [state EXCEPT !["parent"] = "Ready", !["child"] = "Running"]
    /\ current' = [current EXCEPT ![c] = "child"]
    /\ UNCHANGED <<stands, owner, reapPending>>

\* The exception return completes the physical switch: the core leaves the
\* stack it stood on (releasing it unless it is the idle stack) and takes
\* ownership of its current process's stack.
SwitchComplete(c) ==
    /\ current[c] # None
    /\ stands[c] # current[c]
    /\ owner[current[c]] = None
    /\ owner' = [p \in Procs |->
                   IF p = current[c] THEN c
                   ELSE IF p = stands[c] THEN None
                   ELSE owner[p]]
    /\ stands' = [stands EXCEPT ![c] = current[c]]
    /\ UNCHANGED <<state, current, reapPending>>

\* The parent calls wait4 before the child has exited and blocks. No
\* successor is Ready here, so the core has no current process and still
\* stands on the parent's stack.
Wait4Block(c) ==
    /\ Settled(c, "parent")
    /\ state["child"] \in {"Ready", "Running"}
    /\ ~reapPending
    /\ state' = [state EXCEPT !["parent"] = "Blocked"]
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED <<stands, owner, reapPending>>

\* The child exits and becomes a zombie. A parent Blocked in wait4 is woken
\* and left Ready with its continuation. The core has no current process
\* and still stands on the zombie's stack.
ChildExit(c) ==
    /\ Settled(c, "child")
    /\ LET wakes == state["parent"] = "Blocked"
       IN  /\ state' = [state EXCEPT
                          !["child"] = "Exited",
                          !["parent"] = IF wakes THEN "Ready" ELSE @]
           /\ reapPending' = (reapPending \/ wakes)
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED <<stands, owner>>

\* A core with no current process moves to its idle stack and releases the
\* stack it stood on: an exited process's (kernel_process_stack_idle_complete),
\* or a blocked one's (kernel_process_stack_idle_blocked).
\* With EXIT_IDLES = FALSE, a core standing on a zombie's stack does not.
IdleEnter(c) ==
    /\ current[c] = None
    /\ stands[c] # Idle
    /\ EXIT_IDLES \/ (stands[c] \in Procs /\ state[stands[c]] # "Exited")
    /\ owner' = [owner EXCEPT ![stands[c]] = None]
    /\ stands' = [stands EXCEPT ![c] = Idle]
    /\ UNCHANGED <<state, current, reapPending>>

\* A core with no current process takes a takeable Ready process. From the
\* idle stack this is the idle loop's take; from a zombie's stack it is the
\* removed kernel_process_exit_await_successor, which only EXIT_IDLES =
\* FALSE still does.
Dispatch(c, p) ==
    /\ current[c] = None
    /\ \/ stands[c] = Idle
       \/ ~EXIT_IDLES /\ stands[c] \in Procs /\ state[stands[c]] = "Exited"
    /\ Takeable(p)
    /\ state' = [state EXCEPT ![p] = "Running"]
    /\ current' = [current EXCEPT ![c] = p]
    /\ UNCHANGED <<stands, owner, reapPending>>

\* The parent finishes wait4 by reaping the zombie: woken from its wait,
\* or calling wait4 after the child has already exited.
Wait4Reap(c) ==
    /\ Settled(c, "parent")
    /\ reapPending \/ state["child"] = "Exited"
    /\ owner["child"] = None
    /\ state' = [state EXCEPT !["child"] = "Reaped"]
    /\ reapPending' = FALSE
    /\ UNCHANGED <<current, stands, owner>>

\* A running process leaves this core without exiting: an excluded process
\* at a syscall return (kernel_process_core0_leave_excluded), a Migrate, a
\* timer leave. The core then enters idle with kernel_process_stack_idle_yield,
\* which makes Ready the process whose stack the core STANDS on and releases
\* that stack. Only asked from the process's own stack when
\* LEAVE_CHECKS_STACK holds.
Leave(c) ==
    /\ current[c] # None
    /\ stands[c] # Idle
    /\ LEAVE_CHECKS_STACK => stands[c] = current[c]
    /\ state' = [state EXCEPT ![stands[c]] = "Ready"]
    /\ owner' = [owner EXCEPT ![stands[c]] = None]
    /\ current' = [current EXCEPT ![c] = None]
    /\ stands' = [stands EXCEPT ![c] = Idle]
    /\ UNCHANGED reapPending

Next ==
    \E c \in Cores :
        \/ Clone(c)
        \/ SwitchComplete(c)
        \/ Wait4Block(c)
        \/ ChildExit(c)
        \/ IdleEnter(c)
        \/ Wait4Reap(c)
        \/ Leave(c)
        \/ \E p \in Procs : Dispatch(c, p)

\* Fairness: each core keeps taking every step open to it except Leave,
\* which is the scheduler's choice and may never happen.
Fairness ==
    \A c \in Cores :
        /\ WF_vars(SwitchComplete(c))
        /\ WF_vars(IdleEnter(c))
        /\ SF_vars(\E p \in Procs : Dispatch(c, p))
        /\ SF_vars(Clone(c))
        /\ SF_vars(Wait4Block(c))
        /\ SF_vars(ChildExit(c))
        /\ SF_vars(Wait4Reap(c))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A p \in Procs :
           state[p] \in {"Unborn", "Ready", "Running", "Blocked", "Exited", "Reaped"}
    /\ \A c \in Cores : current[c] \in Procs \union {None}
    /\ \A c \in Cores : stands[c] \in Procs \union {Idle}
    /\ \A p \in Procs : owner[p] \in Cores \union {None}

\* #601's safety property. A core stands only on a stack it owns; since
\* `owner` names one core per stack, no stack is used by two cores at once.
\* A running process on its own stack therefore runs on a stack it owns.
StackSafety ==
    \A c \in Cores : stands[c] \in Procs => owner[stands[c]] = c

\* A process is Running exactly when some core has it as current, and on
\* one core only. The lost clone child violates this.
RunningMatchesCores ==
    /\ \A p \in Procs :
           (state[p] = "Running") <=> (\E c \in Cores : current[c] = p)
    /\ \A c, d \in Cores :
           (c # d /\ current[c] # None) => current[c] # current[d]

\* The parent's wait4 completes: the child is reaped.
ChildReaped == <>(state["child"] = "Reaped")

----------------------------------------------------------------------------
(* Constant initializers for Apalache. *)

CInitFixed == EXIT_IDLES = TRUE /\ LEAVE_CHECKS_STACK = TRUE
CInitExitWaits == EXIT_IDLES = FALSE /\ LEAVE_CHECKS_STACK = TRUE
CInitLeaveUnchecked == EXIT_IDLES = TRUE /\ LEAVE_CHECKS_STACK = FALSE

=============================================================================
