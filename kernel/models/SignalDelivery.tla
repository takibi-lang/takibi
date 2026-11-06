--------------------------- MODULE SignalDelivery ---------------------------
(***************************************************************************)
(* Where a return to EL0 meets a signal (GitHub issue #1000).              *)
(*                                                                         *)
(* One process, one sender, one blocking call. The process makes the call *)
(* once (a plain sleeping call, with or without SA_RESTART, or            *)
(* rt_sigsuspend, which swaps the signal mask for the call), then computes *)
(* without syscalls. The sender raises one signal, caught or terminating,  *)
(* at any point. The kernel decides delivery in one function,             *)
(* signal_deliver, entered from three places: the syscall's own return    *)
(* (SyscallReturn), the Block return a caught signal interrupted          *)
(* (Interrupted), and every other return to EL0, the stack-switch hook's  *)
(* (ReturnToUser).                                                         *)
(*                                                                         *)
(* The four unfixed variants are the kernel before the fixes the one      *)
(* function now holds together:                                            *)
(*   WAKE = FALSE         before #726: a signal does not wake a sleeper;  *)
(*   IRQDELIVER = FALSE   before #628: a handler runs only at a syscall   *)
(*                        return;                                          *)
(*   IRQTERM = FALSE      before #949: a terminating signal ends the      *)
(*                        process only at a syscall;                       *)
(*   RESTARTTAKES = FALSE a restart that leaves the signal pending, so    *)
(*                        the rerun restarts again.                        *)
(*                                                                         *)
(* Each action is one critical section in the kernel; README.md maps them. *)
(***************************************************************************)

EXTENDS Integers

CONSTANT
    \* @type: Bool;
    WAKE,
    \* @type: Bool;
    IRQDELIVER,
    \* @type: Bool;
    IRQTERM,
    \* @type: Bool;
    RESTARTTAKES

VARIABLES
    \* @type: Str;
    pc,         \* "call" | "asleep" | "rerun" | "handler" | "spin" | "ended"
    \* @type: Str;
    call,       \* the call made: "plain" | "restart" | "suspend"
    \* @type: Str;
    sig,        \* the pending signal: "none" | "caught" | "term"
    \* @type: Bool;
    sent,       \* the sender has raised its signal
    \* @type: Bool;
    handled,    \* a handler ran for it
    \* @type: Str;
    after,      \* where the handler returns to: "rerun" | "spin"
    \* @type: Bool;
    eintr,      \* the process has seen the call answer EINTR
    \* @type: Int;
    restarts,   \* how many times the call was rewound for this signal
    \* @type: Bool;
    swapped,    \* rt_sigsuspend's mask is in force
    \* @type: Bool;
    missed      \* a return to EL0 left a deliverable signal untaken

vars == <<pc, call, sig, sent, handled, after, eintr, restarts, swapped, missed>>

----------------------------------------------------------------------------

Init ==
    /\ pc = "call"
    /\ call \in {"plain", "restart", "suspend"}
    /\ sig = "none"
    /\ sent = FALSE
    /\ handled = FALSE
    /\ after = "spin"
    /\ eintr = FALSE
    /\ restarts = 0
    /\ swapped = FALSE
    /\ missed = FALSE

\* The handler entry signal_handler_enter makes: the frame records the
\* interrupted context (and the mask rt_sigsuspend swapped out), the signal
\* is taken.
\* @type: (Str) => Bool;
EnterHandler(back) ==
    /\ pc' = "handler"
    /\ after' = back
    /\ sig' = "none"
    /\ handled' = TRUE

\* kernel_process_signal_deliver_to: the signal becomes pending; with WAKE
\* a sleeper is woken to rerun its call.
Send ==
    /\ ~sent
    /\ pc # "ended"
    /\ sent' = TRUE
    /\ \E s \in {"caught", "term"} : sig' = s
    /\ pc' = IF WAKE /\ pc = "asleep" THEN "rerun" ELSE pc
    /\ UNCHANGED <<call, handled, after, eintr, restarts, swapped, missed>>

\* The syscall: its entry ends the process for a terminating signal;
\* otherwise its Block return either sleeps or, a caught signal pending,
\* goes through signal_deliver(Interrupted): rewound under SA_RESTART,
\* EINTR otherwise, the handler entered first either way.
Call ==
    /\ pc \in {"call", "rerun"}
    /\ IF sig = "term"
         THEN /\ pc' = "ended"
              /\ sig' = "none"
              /\ UNCHANGED <<handled, after, eintr, restarts, swapped>>
       ELSE IF sig = "caught"
         THEN IF call = "restart"
                THEN /\ restarts' = restarts + 1
                     /\ IF RESTARTTAKES
                          THEN EnterHandler("rerun")
                          ELSE /\ pc' = "rerun"
                               /\ UNCHANGED <<sig, handled, after>>
                     /\ UNCHANGED <<eintr, swapped>>
                ELSE /\ EnterHandler("spin")
                     /\ eintr' = FALSE
                     /\ UNCHANGED <<restarts, swapped>>
       ELSE /\ pc' = "asleep"
            /\ swapped' = (call = "suspend")
            /\ UNCHANGED <<sig, handled, after, eintr, restarts>>
    /\ UNCHANGED <<call, sent, missed>>

\* The wait ends of its own accord (the child exits, the time passes):
\* the call returns through signal_deliver(SyscallReturn), which takes a
\* caught signal pending by then, or ends the rt_sigsuspend swap.
Complete ==
    /\ pc = "asleep"
    /\ call # "suspend"
    /\ IF sig = "caught"
         THEN /\ EnterHandler("spin")
         ELSE /\ pc' = "spin"
              /\ UNCHANGED <<sig, handled, after>>
    /\ swapped' = FALSE
    /\ UNCHANGED <<call, sent, eintr, restarts, missed>>

\* The handler's rt_sigreturn: the frame comes back, the mask with it. A
\* call it interrupted without a restart now sees its EINTR.
HandlerReturn ==
    /\ pc = "handler"
    /\ pc' = after
    /\ swapped' = FALSE
    /\ eintr' = ((after = "spin" /\ restarts = 0) \/ eintr)
    /\ UNCHANGED <<call, sig, sent, handled, after, restarts, missed>>

\* An interrupt's return to EL0 while the process computes:
\* signal_deliver(ReturnToUser). A terminating signal ends it (IRQTERM); a
\* caught one enters its handler (IRQDELIVER). A deliverable signal left
\* untaken is recorded as missed.
Tick ==
    /\ pc = "spin"
    /\ IF sig = "term" /\ IRQTERM
         THEN /\ pc' = "ended"
              /\ sig' = "none"
              /\ UNCHANGED <<handled, after, missed>>
       ELSE IF sig = "caught" /\ IRQDELIVER
         THEN EnterHandler("spin") /\ UNCHANGED missed
       ELSE /\ missed' = (missed \/ sig # "none")
            /\ UNCHANGED <<pc, sig, handled, after>>
    /\ UNCHANGED <<call, sent, eintr, restarts, swapped>>

Done ==
    /\ pc \in {"ended", "spin"}
    /\ sent
    /\ sig = "none"
    /\ UNCHANGED vars

Next == Send \/ Call \/ Complete \/ HandlerReturn \/ Tick \/ Done

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ pc \in {"call", "asleep", "rerun", "handler", "spin", "ended"}
    /\ call \in {"plain", "restart", "suspend"}
    /\ sig \in {"none", "caught", "term"}
    /\ restarts \in 0..3

\* A raised signal is pending until a handler ran or the process ended
\* (TakenSignal's rule).
NeverLost == sent => (sig # "none" \/ handled \/ pc = "ended")

\* No one sleeps in the call with a caught signal pending (#726).
NoSleepWithSignal == pc = "asleep" => sig = "none"

\* A call is rewound at most once for its signal.
RestartOnce == restarts <= 1

\* The call's EINTR is seen only after the handler ran.
HandlerBeforeEintr == eintr => handled

\* rt_sigsuspend's mask is not in force once the process computes again.
SuspendEnds == pc = "spin" => ~swapped

\* Every return to EL0 takes what it can deliver: a terminating signal
\* needs no syscall (#949), a caught one runs its handler (#628).
NoMissedReturn == ~missed

Safety ==
    /\ NeverLost /\ NoSleepWithSignal /\ RestartOnce
    /\ HandlerBeforeEintr /\ SuspendEnds /\ NoMissedReturn

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == WAKE = TRUE /\ IRQDELIVER = TRUE /\ IRQTERM = TRUE /\ RESTARTTAKES = TRUE
CInitNoWake == WAKE = FALSE /\ IRQDELIVER = TRUE /\ IRQTERM = TRUE /\ RESTARTTAKES = TRUE
CInitNoIrqDeliver == WAKE = TRUE /\ IRQDELIVER = FALSE /\ IRQTERM = TRUE /\ RESTARTTAKES = TRUE
CInitNoIrqTerm == WAKE = TRUE /\ IRQDELIVER = TRUE /\ IRQTERM = FALSE /\ RESTARTTAKES = TRUE
CInitRestartTwice == WAKE = TRUE /\ IRQDELIVER = TRUE /\ IRQTERM = TRUE /\ RESTARTTAKES = FALSE

=============================================================================
