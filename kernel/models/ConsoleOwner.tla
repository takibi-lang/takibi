---------------------------- MODULE ConsoleOwner ----------------------------
EXTENDS Integers

(***************************************************************************)
(* Console ownership by priority, from any core (GitHub issue #830,        *)
(* maintainer decision 2026-10-23, option C, after Linux's nbcon).          *)
(*                                                                         *)
(* One atomic word says who owns the console beyond ordinary queued output:*)
(* an owner priority and cpu (priority 0: nobody) and a TERMINAL bit. The   *)
(* transmit queue is live when the platform armed it and the word is zero.  *)
(* A path entered with interrupts masked takes the word by compare-swap at  *)
(* its own priority, succeeding only over a strictly lower one:             *)
(*   1 emergency (stack guard), 2 debugger (DDB), 3 panic (crash console).  *)
(* Emergency and panic never return; they set TERMINAL even when outranked.*)
(* DDB returns, and gives back the owner it displaced only while its own    *)
(* owner field is still there, keeping TERMINAL.                            *)
(*                                                                         *)
(* BLIND = TRUE is the former resume: it stores the found state back       *)
(* unconditionally. NOSTICKY = TRUE is the outranked emergency that leaves  *)
(* no mark. Each lets a DDB that continues make the queue live again while  *)
(* another core is in a terminal path that will never drain it. TLC must    *)
(* find TerminalStays violated in both.                                     *)
(*                                                                         *)
(* kernel/models/README.md maps each action to the functions it abstracts.  *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    BLIND,
    \* @type: Bool;
    NOSTICKY

CPUS == {1, 2}

VARIABLES
    \* @type: Bool;
    armed,       \* the platform armed the transmit interrupt
    \* @type: Int;
    oprio,       \* owner priority, 0 .. 3; 0 is nobody
    \* @type: Int;
    ocpu,        \* owner cpu; 0 with nobody
    \* @type: Bool;
    term,        \* TERMINAL: a non-returning path has been entered
    \* @type: Int -> Str;
    pc,          \* "run" | "ddb" (holding a DDB token) | "dead" (terminal)
    \* @type: Int -> Int;
    fprio,       \* the owner priority DDB's token found
    \* @type: Int -> Int;
    fcpu         \* the owner cpu DDB's token found

vars == <<armed, oprio, ocpu, term, pc, fprio, fcpu>>

Live == armed /\ oprio = 0 /\ ~term

Init ==
    /\ armed = FALSE
    /\ oprio = 0
    /\ ocpu = 0
    /\ term = FALSE
    /\ pc = [c \in CPUS |-> "run"]
    /\ fprio = [c \in CPUS |-> 0]
    /\ fcpu = [c \in CPUS |-> 0]

\* kernel_log_tx_activate: the platform armed its TX interrupt.
Activate ==
    /\ ~armed
    /\ armed' = TRUE
    /\ UNCHANGED <<oprio, ocpu, term, pc, fprio, fcpu>>

\* kernel_ddb_enter_stopped -> kernel_log_tx_stand_down(DEBUGGER): one
\* successful compare-swap, or Outranked with no token.
EnterDdb(c) ==
    /\ pc[c] = "run"
    /\ IF oprio >= 2
         THEN UNCHANGED <<oprio, ocpu, pc, fprio, fcpu>>
         ELSE /\ oprio' = 2
              /\ ocpu' = c
              /\ fprio' = [fprio EXCEPT ![c] = oprio]
              /\ fcpu' = [fcpu EXCEPT ![c] = ocpu]
              /\ pc' = [pc EXCEPT ![c] = "ddb"]
    /\ UNCHANGED <<armed, term>>

\* kernel_log_enter_emergency (p = 1) and crash_console_run (p = 3):
\* kernel_log_tx_stand_down at a non-returning priority, from a running core
\* or from inside DDB on the same core.
Terminal(c, p) ==
    /\ pc[c] \in {"run", "ddb"}
    /\ IF oprio >= p
         THEN /\ term' = (term \/ ~NOSTICKY)
              /\ UNCHANGED <<oprio, ocpu>>
         ELSE /\ oprio' = p
              /\ ocpu' = c
              /\ term' = TRUE
    /\ pc' = [pc EXCEPT ![c] = "dead"]
    /\ UNCHANGED <<armed, fprio, fcpu>>

\* kernel_log_tx_resume at DDB's continue.
Resume(c) ==
    /\ pc[c] = "ddb"
    /\ IF BLIND
         THEN /\ oprio' = fprio[c]
              /\ ocpu' = fcpu[c]
              /\ term' = FALSE
         ELSE /\ IF oprio = 2 /\ ocpu = c
                    THEN /\ oprio' = fprio[c]
                         /\ ocpu' = fcpu[c]
                    ELSE UNCHANGED <<oprio, ocpu>>
              /\ UNCHANGED term
    /\ pc' = [pc EXCEPT ![c] = "run"]
    /\ UNCHANGED <<armed, fprio, fcpu>>

\* Every core in a terminal path: a stuttering step, so the end is not a
\* deadlock.
Halted ==
    /\ \A c \in CPUS : pc[c] = "dead"
    /\ UNCHANGED vars

Next ==
    \/ Halted
    \/ Activate
    \/ \E c \in CPUS : EnterDdb(c)
    \/ \E c \in CPUS : \E p \in {1, 3} : Terminal(c, p)
    \/ \E c \in CPUS : Resume(c)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ oprio \in 0 .. 3
    /\ ocpu \in 0 .. 2
    /\ \A c \in CPUS : pc[c] \in {"run", "ddb", "dead"}

\* Once a core is in a path that never returns, nothing drains the queue for
\* it, so the queue must never be live again.
TerminalStays == (\E c \in CPUS : pc[c] = "dead") => ~Live

\* With no terminal path entered and no DDB holding the console, nobody owns
\* it: DDB's continue put back what it found.
DdbRestores ==
    (\A c \in CPUS : pc[c] = "run") => (oprio = 0 /\ ~term)

Safety == TypeOK /\ TerminalStays /\ DdbRestores

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == BLIND = FALSE /\ NOSTICKY = FALSE
CInitBlind == BLIND = TRUE /\ NOSTICKY = FALSE
CInitNoSticky == BLIND = FALSE /\ NOSTICKY = TRUE

=============================================================================
