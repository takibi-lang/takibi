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
(* GitHub issue #726 adds the same window for a caught signal. A signal   *)
(* raised while the parent is Blocked wakes it, and its rerun of wait4    *)
(* answers EINTR at the Block return. One raised between the decision and *)
(* the publication finds the parent Running and wakes nobody, so the      *)
(* publication must re-check it too: SIGRECHECK = FALSE is the kernel     *)
(* without that re-check, and TLC must find NoSleepWithSignal violated.   *)
(*                                                                         *)
(* GitHub issue #628 adds the other place a handler runs: the return to   *)
(* EL0 from a timer interrupt (TickDeliver). IRQDELIVER = FALSE is the    *)
(* kernel before it: a parent that has finished wait4 and computes without *)
(* a syscall never runs its handler, and TLC must find SignalRuns          *)
(* violated. That return must leave a signal pending when the parent is   *)
(* at its wait4 SVC -- the rerun a signal's wake rewound it to -- so that  *)
(* the rerun meets the signal and ends with EINTR. IRQSKIPSVC = FALSE      *)
(* takes it there, and TLC must find SignalWakeEndsWait violated: the      *)
(* handler runs, and the rerun goes back to sleep.                         *)
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
    RECHECK,
    \* @type: Bool;
    SIGRECHECK,
    \* @type: Bool;
    IRQDELIVER,
    \* @type: Bool;
    IRQSKIPSVC

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
    wait,       \* the parent's wait4: "call" | "decided" | "asleep" | "woken" | "done"
    \* @type: Bool;
    sig,        \* a signal the parent catches, and does not mask, is pending
    \* @type: Bool;
    woke        \* a signal woke the parent's wait4 to rerun it (#726)

vars == <<state, current, wait, sig, woke>>

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
    /\ sig = FALSE
    /\ woke = FALSE

----------------------------------------------------------------------------
(* Actions *)

\* wait4's decision. A zombie child is reaped at once; otherwise the
\* parent records that it will block, and is still Running. A pending
\* caught signal ends the call at its Block return instead (EINTR; the
\* handler runs and the signal is no longer pending). The Block return is
\* a critical section of its own in the kernel (syscall_block_interrupt);
\* the window after it is the one Wait4Block re-checks.
Wait4Decide ==
    /\ \E c \in Cores : RunsOn("parent", c)
    /\ wait = "call"
    /\ IF state["child"] = "Exited"
         THEN /\ state' = [state EXCEPT !["child"] = "Reaped"]
              /\ wait' = "done"
              /\ sig' = FALSE
         ELSE IF sig
         THEN /\ wait' = "done"
              /\ sig' = FALSE
              /\ UNCHANGED state
         ELSE /\ wait' = "decided"
              /\ UNCHANGED <<state, sig>>
    /\ UNCHANGED <<current, woke>>

\* Publishing Blocked, and switching this core to a Ready successor --
\* any Ready process, as kernel_process_next_ready picks one -- or, with
\* none, leaving it idle (kernel_process_block_to_idle, open to ChildExit
\* since #550). With RECHECK, an exited child cancels the block and wait4
\* reruns.
Wait4Block ==
    \E c \in Cores :
        /\ RunsOn("parent", c)
        /\ wait = "decided"
        /\ IF (RECHECK /\ state["child"] = "Exited") \/ (SIGRECHECK /\ sig)
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
        /\ UNCHANGED <<sig, woke>>

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
        /\ UNCHANGED <<sig, woke>>

\* Another process sends the parent a signal it catches (#726). The raise
\* and the wake are one critical section (kernel_process_signal_deliver_to):
\* a parent Blocked in wait4 is woken to rerun the call; one that is not
\* Blocked is left to meet the signal at its own Block return, or, once
\* wait4 is done, at a return to EL0 (#628).
SendSignal ==
    /\ ~sig
    /\ wait \in {"call", "decided", "asleep", "done"}
    /\ sig' = TRUE
    /\ IF state["parent"] = "Blocked" /\ wait = "asleep"
         THEN /\ state' = [state EXCEPT !["parent"] = "Ready"]
              /\ wait' = "call"
              /\ woke' = TRUE
         ELSE UNCHANGED <<state, wait, woke>>
    /\ UNCHANGED current

\* #628: the return to EL0 from a timer interrupt runs the handler of a
\* pending signal (kernel_signal_return_deliver, from the stack-switch
\* hook). "call" is the parent at its wait4 SVC -- before the first call,
\* or rewound there by a signal's wake -- and "done" is user code after
\* it; in between it is in the kernel or asleep, where no interrupt
\* returns to EL0. With IRQSKIPSVC, a parent at its SVC keeps the signal
\* for the syscall it is about to make (signal_resumes_at_svc).
TickDeliver ==
    /\ IRQDELIVER
    /\ sig
    /\ \E c \in Cores : RunsOn("parent", c)
    /\ wait \in (IF IRQSKIPSVC THEN {"done"} ELSE {"call", "done"})
    /\ sig' = FALSE
    /\ UNCHANGED <<state, current, wait, woke>>

\* A woken parent runs again and finishes wait4 by reaping the zombie.
Wait4Resume ==
    /\ \E c \in Cores : RunsOn("parent", c)
    /\ wait = "woken"
    /\ state' = [state EXCEPT !["child"] = "Reaped"]
    /\ wait' = "done"
    /\ sig' = FALSE
    /\ UNCHANGED <<current, woke>>

\* The timer takes a Running process off its core.
Preempt(c) ==
    /\ current[c] # None
    /\ Preemptible(current[c])
    /\ state' = [state EXCEPT ![current[c]] = "Ready"]
    /\ current' = [current EXCEPT ![c] = None]
    /\ UNCHANGED <<wait, sig, woke>>

\* An idle core takes a Ready process.
\* @type: (Str, Str) => Bool;
Dispatch(c, p) ==
    /\ current[c] = None
    /\ state[p] = "Ready"
    /\ state' = [state EXCEPT ![p] = "Running"]
    /\ current' = [current EXCEPT ![c] = p]
    /\ UNCHANGED <<wait, sig, woke>>

Next ==
    \/ Wait4Decide
    \/ Wait4Block
    \/ ChildExit
    \/ Wait4Resume
    \/ SendSignal
    \/ TickDeliver
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
    /\ SF_vars(TickDeliver)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A p \in Procs :
           state[p] \in {"Ready", "Running", "Blocked", "Exited", "Reaped"}
    /\ \A c \in Cores : current[c] \in Procs \union {None}
    /\ wait \in {"call", "decided", "asleep", "woken", "done"}
    /\ sig \in BOOLEAN
    /\ woke \in BOOLEAN

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

\* #726: the parent never sleeps in wait4 beside a pending signal it
\* catches. Its handler would wait for the child, not run at once.
NoSleepWithSignal ==
    ~(state["parent"] = "Blocked" /\ wait = "asleep" /\ sig)

\* #628: a wait4 that a signal woke is never asleep again. Its rerun meets
\* the signal and ends with EINTR, or reaps the child that has exited.
SignalWakeEndsWait ==
    ~(woke /\ wait = "asleep")

\* The safety properties at once, for Apalache's shallow runs.
Safety == NoLostWakeup /\ NoSleepWithSignal /\ SignalWakeEndsWait

\* #550, as the liveness property #601 asks for: wait4 finishes.
Wait4Finishes == <>(wait = "done")

\* #628, liveness: a pending caught signal is eventually handled, even by
\* a parent that makes no further syscall.
SignalRuns == sig ~> ~sig

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == RECHECK = TRUE /\ SIGRECHECK = TRUE /\
    IRQDELIVER = TRUE /\ IRQSKIPSVC = TRUE
CInitUnfixed == RECHECK = FALSE /\ SIGRECHECK = TRUE /\
    IRQDELIVER = TRUE /\ IRQSKIPSVC = TRUE
CInitSigUnfixed == RECHECK = TRUE /\ SIGRECHECK = FALSE /\
    IRQDELIVER = TRUE /\ IRQSKIPSVC = TRUE
CInitIrqUnfixed == RECHECK = TRUE /\ SIGRECHECK = TRUE /\
    IRQDELIVER = FALSE /\ IRQSKIPSVC = TRUE
CInitSvcUnfixed == RECHECK = TRUE /\ SIGRECHECK = TRUE /\
    IRQDELIVER = TRUE /\ IRQSKIPSVC = FALSE

=============================================================================
