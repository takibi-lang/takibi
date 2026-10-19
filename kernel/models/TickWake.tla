----------------------------- MODULE TickWake ------------------------------
(***************************************************************************)
(* Per-CPU tick-wake lists (GitHub issue #829).                            *)
(*                                                                         *)
(* A process blocked on a wait that a tick ends -- a deadline or a NetRx   *)
(* retry -- is queued when it publishes Blocked, and a tick that walks the *)
(* list it is on wakes it once it is due. Before #829 one list existed in  *)
(* effect, every slot, and only core 0's tick walked it, so a long core-0  *)
(* mask (DDB) delayed a sleeper on every core.                             *)
(*                                                                         *)
(* PERCPU = TRUE is the kernel since #829: a sleeper is queued on the list *)
(* of the core it blocked on, and each core's tick walks its own list.     *)
(* PERCPU = FALSE is the kernel before: core 0's tick is the only walker.  *)
(* With core 0 masked for good, TLC must find a sleeper on core 1 that is  *)
(* never woken (PeerSleeperWakes).                                         *)
(*                                                                         *)
(* UNLINK = FALSE is a wake that is not the tick (a signal) leaving the    *)
(* record on its list; TLC must find ListsMatchBlocked violated.           *)
(*                                                                         *)
(* An affinity change does not move a queued sleeper (SetAffinity): the   *)
(* kernel's wake only publishes Ready, so the core that queued it wakes it *)
(* and any allowed core then runs it. The fixed variant checks that this  *)
(* loses no wake.                                                          *)
(*                                                                         *)
(* Each action is one critical section under the process-run lock, except *)
(* Expire (time passing) and Mask (core 0 entering a long masked section). *)
(* kernel/models/README.md maps every action to the function it abstracts. *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    PERCPU,
    \* @type: Bool;
    UNLINK

Cores == {"c0", "c1"}
Procs == {"p1", "p2"}

VARIABLES
    \* @type: Str -> Str;
    state,      \* per process: "Running" | "Blocked" | "Ready"
    \* @type: Str -> Str;
    home,       \* per process: the core it runs on, which its mask allows
    \* @type: Str -> Str;
    blockedOn,  \* per process: the core that ran its last block
    \* @type: Str -> Bool;
    due,        \* per process: its deadline has passed
    \* @type: Str -> Set(Str);
    list,       \* per core: the processes queued on its tick-wake list
    \* @type: Bool;
    masked      \* core 0 has entered a masked section it never leaves

vars == <<state, home, blockedOn, due, list, masked>>

\* The list a block on core c queues on.
\* @type: (Str) => Str;
QueueOf(c) == IF PERCPU THEN c ELSE "c0"

Init ==
    /\ state = [p \in Procs |-> "Running"]
    /\ home = [p \in Procs |-> IF p = "p1" THEN "c0" ELSE "c1"]
    /\ blockedOn = home
    /\ due = [p \in Procs |-> FALSE]
    /\ list = [c \in Cores |-> {}]
    /\ masked = FALSE

----------------------------------------------------------------------------
(* Actions *)

\* scheduled_process_block: the process publishes Blocked on a tick wait
\* and is queued, in the same critical section.
\* @type: (Str) => Bool;
Block(p) ==
    /\ state[p] = "Running"
    /\ ~(masked /\ home[p] = "c0")
    /\ state' = [state EXCEPT ![p] = "Blocked"]
    /\ blockedOn' = [blockedOn EXCEPT ![p] = home[p]]
    /\ due' = [due EXCEPT ![p] = FALSE]
    /\ list' = [list EXCEPT ![QueueOf(home[p])] = @ \union {p}]
    /\ UNCHANGED <<home, masked>>

\* Time passes the sleeper's deadline (a NetRx retry is due at once).
\* @type: (Str) => Bool;
Expire(p) ==
    /\ state[p] = "Blocked"
    /\ ~due[p]
    /\ due' = [due EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<state, home, blockedOn, list, masked>>

\* kernel_process_tick_wake_scan: core c's tick wakes what is due on its
\* own list. A masked core takes no tick.
\* @type: (Str) => Bool;
Tick(c) ==
    /\ ~(masked /\ c = "c0")
    /\ \E p \in list[c] : due[p]
    /\ LET woken == {p \in list[c] : due[p]}
       IN  /\ state' = [p \in Procs |->
                           IF p \in woken THEN "Ready" ELSE state[p]]
           /\ list' = [list EXCEPT ![c] = @ \ woken]
    /\ UNCHANGED <<home, blockedOn, due, masked>>

\* A wake that is not the tick: a signal ends the wait early. With UNLINK
\* it takes the record off its list (scheduled_process_wake_ready).
\* @type: (Str) => Bool;
SignalWake(p) ==
    /\ state[p] = "Blocked"
    /\ state' = [state EXCEPT ![p] = "Ready"]
    /\ list' = IF UNLINK
                 THEN [c \in Cores |-> list[c] \ {p}]
                 ELSE list
    /\ UNCHANGED <<home, blockedOn, due, masked>>

\* A Ready process runs again on the core its mask allows.
\* @type: (Str) => Bool;
Run(p) ==
    /\ state[p] = "Ready"
    /\ ~(masked /\ home[p] = "c0")
    /\ state' = [state EXCEPT ![p] = "Running"]
    /\ UNCHANGED <<home, blockedOn, due, list, masked>>

\* sched_setaffinity, from any process, on a sleeper or not: the mask
\* changes and a queued sleeper stays where it is.
\* @type: (Str, Str) => Bool;
SetAffinity(p, c) ==
    /\ home[p] # c
    /\ home' = [home EXCEPT ![p] = c]
    /\ UNCHANGED <<state, blockedOn, due, list, masked>>

\* Core 0 enters a long masked section (DDB, a masked probe) for good.
Mask ==
    /\ ~masked
    /\ masked' = TRUE
    /\ UNCHANGED <<state, home, blockedOn, due, list>>

Next ==
    \/ \E p \in Procs : Block(p) \/ Expire(p) \/ SignalWake(p) \/ Run(p)
    \/ \E c \in Cores : Tick(c)
    \/ \E p \in Procs, c \in Cores : SetAffinity(p, c)
    \/ Mask

\* Every unmasked core keeps ticking, and time keeps passing.
Fairness ==
    /\ \A c \in Cores : WF_vars(Tick(c))
    /\ \A p \in Procs : WF_vars(Expire(p))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ \A p \in Procs : state[p] \in {"Running", "Blocked", "Ready"}
    /\ \A p \in Procs : home[p] \in Cores /\ blockedOn[p] \in Cores
    /\ \A c \in Cores : list[c] \subseteq Procs

\* A process is on a list exactly while it is Blocked, and on one list.
ListsMatchBlocked ==
    /\ \A p \in Procs :
           (state[p] = "Blocked") <=> (\E c \in Cores : p \in list[c])
    /\ \A p \in Procs : \A c, d \in Cores :
           (c # d /\ p \in list[c]) => p \notin list[d]

\* #829: a due sleeper that blocked on core 1 is woken although core 0 is
\* masked for good.
PeerSleeperWakes ==
    \A p \in Procs :
        [](state[p] = "Blocked" /\ due[p] /\ blockedOn[p] = "c1"
             => <>(state[p] # "Blocked"))

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == PERCPU = TRUE /\ UNLINK = TRUE
CInitCore0Only == PERCPU = FALSE /\ UNLINK = TRUE
CInitNoUnlink == PERCPU = TRUE /\ UNLINK = FALSE

=============================================================================
