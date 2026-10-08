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
(* Every action is one hold of the process-run lock, as the kernel takes  *)
(* it -- GitHub issue #606's trace of real runs is what showed where the  *)
(* holds really fall. Three kernel sequences are two holds, not one:      *)
(*                                                                         *)
(* - A switch RESERVES its successor (Ready -> Running, `reserved[c]`),   *)
(*   drops the lock to prepare the address space, and COMMITS it as the   *)
(*   core's current process in a later hold.                               *)
(* - A clone makes the child current while it is still Constructing, and  *)
(*   finishes it (child Running, parent Ready) in a later hold.           *)
(* - A process leaving its core stops being current first, and hands its  *)
(*   stack back and becomes Ready once the core stands on its idle stack. *)
(*                                                                         *)
(* Three past defects are variants, each re-introduced by one constant:    *)
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
(* WAKE_START_CHECKS_STACK = FALSE -- #609's shared stack. The child's    *)
(*   exit reserves its Blocked parent for this core without asking        *)
(*   whether another core still stands on the parent's stack. TLC reports *)
(*   StartsOnFreeStack violated.                                           *)
(*                                                                         *)
(* kernel/models/README.md maps each action to the function it abstracts, *)
(* and scripts/validate_protocol_trace.py replays real runs against these *)
(* actions.                                                                *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    EXIT_IDLES,
    \* @type: Bool;
    LEAVE_CHECKS_STACK,
    \* @type: Bool;
    WAKE_START_CHECKS_STACK

Cores == {"c0", "c1"}
Procs == {"parent", "child"}
None == "none"
Idle == "idle"      \* the core's own idle stack, owned by nobody else

VARIABLES
    \* @type: Str -> Str;
    state,      \* per process: "Constructing" | "Ready" | "Running" | "Blocked" | "Napping" | "Exited" | "Reaped"
    \* @type: Str -> Str;
    current,    \* per core: its logical current process, or None
    \* @type: Str -> Str;
    reserved,   \* per core: the successor it has reserved and not yet committed, or None
    \* @type: Str -> Str;
    stands,     \* per core: the process whose stack it stands on, or Idle
    \* @type: Str -> Str;
    owner,      \* per process: the core owning its stack, or None
    \* @type: Str -> Bool;
    interrupted, \* per core: inside an interrupt taken from EL0
    \* @type: Bool;
    reapPending \* the parent was woken in wait4 and still has to reap the child

vars == <<state, current, reserved, stands, owner, interrupted, reapPending>>

\* "Blocked" is the parent in wait4 (ProcessWaitReason::ChildExit);
\* "Napping" is any other block, here the child's nanosleep.

----------------------------------------------------------------------------
(* Helpers *)

\* The core runs p on p's own stack: the physical switch has completed.
\* @type: (Str, Str) => Bool;
Settled(c, p) == current[c] = p /\ stands[c] = p

\* scheduled_process_ready_take: a Ready process may be started only once no
\* core owns its stack -- and a parent carrying a wait4 continuation only once
\* no core owns the exited child's stack either.
\* An interrupt taken from EL0 moved the core off p's stack and released
\* it, and p is still the core's current process.
\* @type: (Str, Str) => Bool;
Departed(c, p) ==
    interrupted[c] /\ current[c] = p /\ stands[c] = Idle /\ owner[p] = None

\* @type: (Str) => Bool;
Takeable(p) ==
    /\ state[p] = "Ready"
    /\ owner[p] = None
    /\ (p = "parent" /\ reapPending) => owner["child"] = None

\* The parent's wait4 decides to block: the child has not exited and no
\* wake is pending.
WaitsForChild ==
    /\ state["child"] \in {"Running", "Ready", "Napping"}
    /\ ~reapPending

----------------------------------------------------------------------------
(* Initial state: the parent runs on c0 and its child has been allocated;  *)
(* c1 idles.                                                               *)

Init ==
    /\ state = [p \in Procs |-> IF p = "parent" THEN "Running" ELSE "Constructing"]
    /\ current = [c \in Cores |-> IF c = "c0" THEN "parent" ELSE None]
    /\ reserved = [c \in Cores |-> None]
    /\ stands = [c \in Cores |-> IF c = "c0" THEN "parent" ELSE Idle]
    /\ owner = [p \in Procs |-> IF p = "parent" THEN "c0" ELSE None]
    /\ interrupted = [c \in Cores |-> FALSE]
    /\ reapPending = FALSE

----------------------------------------------------------------------------
(* Actions *)

\* clone publishes the child: it becomes the core's current process while
\* still Constructing, and the core still stands on the parent's stack.
CloneBegin(c) ==
    /\ Settled(c, "parent")
    /\ state["child"] = "Constructing"
    /\ reserved[c] = None
    /\ current' = [current EXCEPT ![c] = "child"]
    /\ UNCHANGED <<state, reserved, stands, owner, interrupted, reapPending>>

\* The child's frame is installed: it is Running and the parent Ready.
CloneFinish(c) ==
    /\ current[c] = "child"
    /\ state["child"] = "Constructing"
    /\ state' = [state EXCEPT !["parent"] = "Ready", !["child"] = "Running"]
    /\ UNCHANGED <<current, reserved, stands, owner, interrupted, reapPending>>

\* The exception return completes the physical switch: the core leaves the
\* stack it stood on (releasing it unless it is the idle stack) and takes
\* ownership of its current process's stack.
SwitchComplete(c) ==
    /\ current[c] # None
    /\ state[current[c]] = "Running"
    /\ stands[c] # current[c]
    /\ owner[current[c]] = None
    /\ owner' = [p \in Procs |->
                   IF p = current[c] THEN c
                   ELSE IF p = stands[c] THEN None
                   ELSE owner[p]]
    /\ stands' = [stands EXCEPT ![c] = current[c]]
    /\ interrupted' = [interrupted EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<state, current, reserved, reapPending>>

\* A core reserves a takeable Ready process as its successor. An idle core
\* reserves from its idle stack; a core running a process reserves the
\* successor it will switch to. From a zombie's stack this is the removed
\* kernel_process_exit_await_successor, which only EXIT_IDLES = FALSE
\* still does.
Reserve(c, p) ==
    /\ reserved[c] = None
    /\ \/ current[c] # None /\ state[current[c]] = "Running"
       \/ current[c] = None /\ stands[c] = Idle
       \/ current[c] = None /\ ~EXIT_IDLES
          /\ stands[c] \in Procs /\ state[stands[c]] = "Exited"
    /\ Takeable(p)
    /\ state' = [state EXCEPT ![p] = "Running"]
    /\ reserved' = [reserved EXCEPT ![c] = p]
    /\ UNCHANGED <<current, stands, owner, interrupted, reapPending>>

\* The reserved successor becomes current on a core with no running
\* current process: an idle core, or one whose current process has exited.
Commit(c) ==
    /\ reserved[c] # None
    /\ \/ current[c] = None
       \/ current[c] # None /\ state[current[c]] = "Exited"
    /\ current' = [current EXCEPT ![c] = reserved[c]]
    /\ reserved' = [reserved EXCEPT ![c] = None]
    /\ UNCHANGED <<state, stands, owner, interrupted, reapPending>>

\* The reserved successor replaces a running current process, which is
\* preempted (Ready), napping, or the parent blocking in wait4. The core
\* still stands on the outgoing process's stack -- or, inside an interrupt
\* taken from EL0, on its idle (IRQ) stack, the process's already released.
SwitchAway(c, how) ==
    /\ reserved[c] # None
    /\ current[c] # None
    /\ Settled(c, current[c]) \/ Departed(c, current[c])
    /\ state[current[c]] = "Running"
    /\ \/ how = "Ready"
       \/ how = "Napping" /\ current[c] = "child"
       \/ how = "Blocked" /\ current[c] = "parent" /\ WaitsForChild
    /\ state' = [state EXCEPT ![current[c]] = how]
    /\ current' = [current EXCEPT ![c] = reserved[c]]
    /\ reserved' = [reserved EXCEPT ![c] = None]
    /\ UNCHANGED <<stands, owner, interrupted, reapPending>>

\* A deferred timer request may select another process from the child's
\* clone return before the physical stack switch. The child's installed
\* frame is saved, it becomes Ready, and this core still owns the parent's
\* Ready stack until SwitchComplete takes the reserved successor's stack.
CloneReschedule(c) ==
    /\ current[c] = "child"
    /\ state["child"] = "Running"
    /\ owner["child"] = None
    /\ stands[c] = "parent"
    /\ owner["parent"] = c
    /\ state["parent"] = "Ready"
    /\ ~interrupted[c]
    /\ reserved[c] # None
    /\ state' = [state EXCEPT !["child"] = "Ready"]
    /\ current' = [current EXCEPT ![c] = reserved[c]]
    /\ reserved' = [reserved EXCEPT ![c] = None]
    /\ UNCHANGED <<stands, owner, interrupted, reapPending>>

\* The parent calls wait4 before the child has exited and blocks with no
\* successor. The core has no current process and still stands on the
\* parent's stack.
Wait4Block(c) ==
    /\ Settled(c, "parent")
    /\ reserved[c] = None
    /\ WaitsForChild
    /\ state' = [state EXCEPT !["parent"] = "Blocked"]
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED <<reserved, stands, owner, interrupted, reapPending>>

\* The child naps with no successor, the same way.
Nap(c) ==
    /\ Settled(c, "child")
    /\ reserved[c] = None
    /\ state' = [state EXCEPT !["child"] = "Napping"]
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED <<reserved, stands, owner, interrupted, reapPending>>

\* The nap's deadline passes: the child is Ready, wherever its stack is.
Wake ==
    /\ state["child"] = "Napping"
    /\ state' = [state EXCEPT !["child"] = "Ready"]
    /\ UNCHANGED <<current, reserved, stands, owner, interrupted, reapPending>>

\* The child exits and becomes a zombie. A parent Blocked in wait4 is woken
\* and left Ready with its continuation. The core has no current process
\* and still stands on the zombie's stack.
ChildExit(c) ==
    /\ Settled(c, "child")
    /\ reserved[c] = None
    /\ LET wakes == state["parent"] = "Blocked"
       IN  /\ state' = [state EXCEPT
                          !["child"] = "Exited",
                          !["parent"] = IF wakes THEN "Ready" ELSE @]
           /\ reapPending' = (reapPending \/ wakes)
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED <<reserved, stands, owner, interrupted>>

\* The same exit, when the parent is Blocked in wait4 and this core may run
\* it: the parent is woken and reserved for this core at once, and a later
\* Commit makes it current. Allowed only when no core owns the parent's
\* stack; otherwise ChildExit above leaves it Ready.
\* WAKE_START_CHECKS_STACK = FALSE drops that check.
ChildExitStart(c) ==
    /\ Settled(c, "child")
    /\ reserved[c] = None
    /\ state["parent"] = "Blocked"
    /\ WAKE_START_CHECKS_STACK => owner["parent"] = None
    /\ state' = [state EXCEPT !["child"] = "Exited", !["parent"] = "Running"]
    /\ reserved' = [reserved EXCEPT ![c] = "parent"]
    /\ reapPending' = TRUE
    /\ UNCHANGED <<current, stands, owner, interrupted>>

\* A core with no current process moves to its idle stack and releases the
\* stack it stood on: an exited process's (kernel_process_stack_idle_complete),
\* or a blocked, napping or already woken one's
\* (kernel_process_stack_idle_blocked). With EXIT_IDLES = FALSE, a core
\* standing on a zombie's stack does not.
IdleEnter(c) ==
    /\ current[c] = None
    /\ reserved[c] = None
    /\ stands[c] # Idle
    /\ state[stands[c]] # "Running"
    /\ EXIT_IDLES \/ state[stands[c]] # "Exited"
    /\ owner' = [owner EXCEPT ![stands[c]] = None]
    /\ stands' = [stands EXCEPT ![c] = Idle]
    /\ UNCHANGED <<state, current, reserved, interrupted, reapPending>>

\* The parent finishes wait4 by reaping the zombie: woken from its wait,
\* or calling wait4 after the child has already exited.
Wait4Reap(c) ==
    /\ Settled(c, "parent")
    /\ reapPending \/ state["child"] = "Exited"
    /\ state["child"] = "Exited"
    /\ owner["child"] = None
    /\ state' = [state EXCEPT !["child"] = "Reaped"]
    /\ reapPending' = FALSE
    /\ UNCHANGED <<current, reserved, stands, owner, interrupted>>

\* A running process stops being this core's current process without
\* exiting: an excluded process at a syscall return
\* (kernel_process_core0_leave_excluded), a Migrate, a timer leave. It is
\* still Running, and the core still stands on a stack. Only asked from the
\* process's own stack when LEAVE_CHECKS_STACK holds.
LeaveBegin(c) ==
    /\ current[c] # None
    /\ state[current[c]] = "Running"
    /\ reserved[c] = None
    /\ stands[c] # Idle
    /\ LEAVE_CHECKS_STACK => stands[c] = current[c]
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED <<state, reserved, stands, owner, interrupted, reapPending>>

\* An interrupt taken from EL0: its entry moves the core to its IRQ stack
\* and releases the interrupted process's stack, which stays current and
\* Running. SwitchComplete at the exception return takes it back.
InterruptDepart(c) ==
    /\ current[c] # None
    /\ Settled(c, current[c])
    /\ state[current[c]] = "Running"
    /\ reserved[c] = None
    /\ owner' = [owner EXCEPT ![current[c]] = None]
    /\ stands' = [stands EXCEPT ![c] = Idle]
    /\ interrupted' = [interrupted EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<state, current, reserved, reapPending>>

\* Inside that interrupt, the tick finds the process may no longer run
\* here and nothing else may: it is made Ready, its stack already free, and
\* the core idles.
TickLeave(c) ==
    /\ current[c] # None
    /\ Departed(c, current[c])
    /\ state[current[c]] = "Running"
    /\ reserved[c] = None
    /\ state' = [state EXCEPT ![current[c]] = "Ready"]
    /\ current' = [current EXCEPT ![c] = None]
    /\ interrupted' = [interrupted EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<reserved, stands, owner, reapPending>>

\* On its idle stack, kernel_process_stack_idle_yield makes Ready the
\* process whose stack the core stood on, and releases that stack.
LeaveComplete(c) ==
    /\ current[c] = None
    /\ reserved[c] = None
    /\ stands[c] # Idle
    /\ state[stands[c]] = "Running"
    /\ state' = [state EXCEPT ![stands[c]] = "Ready"]
    /\ owner' = [owner EXCEPT ![stands[c]] = None]
    /\ stands' = [stands EXCEPT ![c] = Idle]
    /\ UNCHANGED <<current, reserved, interrupted, reapPending>>

Next ==
    \/ Wake
    \/ \E c \in Cores :
        \/ CloneBegin(c)
        \/ CloneFinish(c)
        \/ CloneReschedule(c)
        \/ SwitchComplete(c)
        \/ Commit(c)
        \/ Wait4Block(c)
        \/ Nap(c)
        \/ ChildExit(c)
        \/ ChildExitStart(c)
        \/ IdleEnter(c)
        \/ Wait4Reap(c)
        \/ LeaveBegin(c)
        \/ LeaveComplete(c)
        \/ InterruptDepart(c)
        \/ TickLeave(c)
        \/ \E p \in Procs : Reserve(c, p)
        \/ \E how \in {"Ready", "Napping", "Blocked"} : SwitchAway(c, how)

\* Fairness: each core keeps taking every step open to it except the
\* scheduler's own choices -- a nap, a preemption, a leave -- which may
\* never happen. Once begun, a two-hold sequence is finished.
Fairness ==
    /\ WF_vars(Wake)
    /\ \A c \in Cores :
        /\ WF_vars(CloneFinish(c))
        /\ WF_vars(SwitchComplete(c))
        /\ WF_vars(Commit(c))
        /\ WF_vars(IdleEnter(c))
        /\ WF_vars(LeaveComplete(c))
        /\ SF_vars(\E p \in Procs : Reserve(c, p))
        /\ SF_vars(\E how \in {"Ready", "Napping", "Blocked"} : SwitchAway(c, how))
        /\ SF_vars(CloneBegin(c))
        /\ SF_vars(Wait4Block(c))
        /\ SF_vars(ChildExit(c) \/ ChildExitStart(c))
        /\ SF_vars(Wait4Reap(c))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A p \in Procs :
           state[p] \in {"Constructing", "Ready", "Running", "Blocked",
                         "Napping", "Exited", "Reaped"}
    /\ \A c \in Cores : current[c] \in Procs \union {None}
    /\ \A c \in Cores : reserved[c] \in Procs \union {None}
    /\ \A c \in Cores : stands[c] \in Procs \union {Idle}
    /\ \A p \in Procs : owner[p] \in Cores \union {None}
    /\ \A c \in Cores : interrupted[c] \in BOOLEAN

\* #601's safety property. A core stands only on a stack it owns; since
\* `owner` names one core per stack, no stack is used by two cores at once.
\* A running process on its own stack therefore runs on a stack it owns.
StackSafety ==
    \A c \in Cores : stands[c] \in Procs => owner[stands[c]] = c

\* A Running process is held by some core -- as its current process, its
\* reserved successor, or the process whose stack it stands on while that
\* process leaves or finishes a clone -- and no process is current or
\* reserved on two cores. A process that is not Running is nobody's
\* reserved successor, and a current process is Running, still
\* Constructing, or exited and awaiting its successor's commit. The lost
\* clone child violates the first clause.
RunningMatchesCores ==
    /\ \A p \in Procs :
           state[p] = "Running" =>
               \E c \in Cores :
                   current[c] = p \/ reserved[c] = p \/ stands[c] = p
    /\ \A c, d \in Cores :
           c # d =>
               /\ current[c] # None => current[c] # current[d]
               /\ reserved[c] # None => reserved[c] # reserved[d]
               /\ reserved[c] # None => reserved[c] # current[d]
    /\ \A c \in Cores :
           /\ reserved[c] # None => state[reserved[c]] = "Running"
           /\ current[c] # None =>
                  state[current[c]] \in {"Running", "Constructing", "Exited"}

\* A core's current process, and the successor it has reserved, have a
\* stack no OTHER core owns: a process is started only on a free stack, or
\* its own core's. #609's direct start of a parent whose blocking core
\* still stood on its stack violates this.
StartsOnFreeStack ==
    \A c \in Cores :
        /\ current[c] # None => owner[current[c]] \in {None, c}
        /\ reserved[c] # None => owner[reserved[c]] \in {None, c}

\* The one invariant Apalache's shallow check is given: both defects that
\* break a safety property are found through it.
CoreInvariants == RunningMatchesCores /\ StartsOnFreeStack

\* The parent's wait4 completes: the child is reaped.
ChildReaped == <>(state["child"] = "Reaped")

----------------------------------------------------------------------------
(* Constant initializers for Apalache. *)

CInitFixed ==
    EXIT_IDLES = TRUE /\ LEAVE_CHECKS_STACK = TRUE /\ WAKE_START_CHECKS_STACK = TRUE
CInitExitWaits ==
    EXIT_IDLES = FALSE /\ LEAVE_CHECKS_STACK = TRUE /\ WAKE_START_CHECKS_STACK = TRUE
CInitLeaveUnchecked ==
    EXIT_IDLES = TRUE /\ LEAVE_CHECKS_STACK = FALSE /\ WAKE_START_CHECKS_STACK = TRUE
CInitWakeStartUnchecked ==
    EXIT_IDLES = TRUE /\ LEAVE_CHECKS_STACK = TRUE /\ WAKE_START_CHECKS_STACK = FALSE

=============================================================================
