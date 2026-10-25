----------------------------- MODULE PipeWait ------------------------------
EXTENDS Integers

(***************************************************************************)
(* A pipe's reader and writer on two CPUs (GitHub issue #1042).            *)
(*                                                                         *)
(* The writer writes ITEMS one-byte writes into a pipe that holds CAP      *)
(* bytes, then closes its end; the reader reads until end of file. A look  *)
(* at the pipe is one critical section under the pipe's lock. One that     *)
(* must wait names the pipe in its process record and sets the pipe's      *)
(* waiting flag (pipe_put_waiting), and the syscall then publishes Blocked *)
(* in a later critical section under the run lock. A change -- a byte      *)
(* consumed or produced, the write end closed -- reads and clears the      *)
(* waiting flag under the pipe lock, and when it was set walks the process *)
(* records under the run lock (pipe_put_changed, kernel_process_pipe_wake):*)
(* each record naming the pipe loses the name, and one Blocked on it       *)
(* becomes runnable and looks again.                                       *)
(*                                                                         *)
(* NAMED_UNDER_LOCK = FALSE names the pipe after the pipe lock is let go,  *)
(* in a section of its own: a change between the look and the name finds   *)
(* the flag clear and wakes nobody. RECHECK = FALSE is a Blocked           *)
(* publication that does not ask whether a wake already took the name: a   *)
(* change between the name and the block clears it while the waiter is    *)
(* still Running, and it then sleeps. TLC must find NoLostWakeup violated  *)
(* by each.                                                                *)
(*                                                                         *)
(* Bytes are a count, not data: the ring's order is the user copy's, under *)
(* the same lock, and no wait depends on it.                               *)
(*                                                                         *)
(* kernel/models/README.md maps each action to the functions it abstracts. *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    NAMED_UNDER_LOCK,
    \* @type: Bool;
    RECHECK

ITEMS == 2
CAP == 1
Procs == {"r", "w"}

VARIABLES
    \* @type: Int;
    buf,         \* bytes buffered, 0 .. CAP
    \* @type: Int;
    written,     \* bytes the writer has written, 0 .. ITEMS
    \* @type: Int;
    got,         \* bytes the reader has read
    \* @type: Bool;
    writerOpen,  \* the write end is open
    \* @type: Bool;
    waiting,     \* the pipe's waiting flag
    \* @type: Str -> Bool;
    named,       \* per process: its record's pipe_wait names this pipe
    \* @type: Str -> Str;
    pc           \* per process: "look" | "decided" | "named" | "asleep" |
                 \* "walk" | "done"

vars == <<buf, written, got, writerOpen, waiting, named, pc>>

Init ==
    /\ buf = 0
    /\ written = 0
    /\ got = 0
    /\ writerOpen = TRUE
    /\ waiting = FALSE
    /\ named = [p \in Procs |-> FALSE]
    /\ pc = [p \in Procs |-> "look"]

----------------------------------------------------------------------------
(* Actions *)

\* After a change: walk only when somebody waited, else carry on looking.
\* @type: (Str, Str) => Str;
AfterChange(p, next) == IF waiting THEN "walk" ELSE next

\* The look that must wait: name the pipe now (under the lock) or decide
\* only, and name it in a later section.
\* @type: (Str) => Bool;
MustWait(p) ==
    IF NAMED_UNDER_LOCK
      THEN /\ named' = [named EXCEPT ![p] = TRUE]
           /\ waiting' = TRUE
           /\ pc' = [pc EXCEPT ![p] = "named"]
      ELSE /\ pc' = [pc EXCEPT ![p] = "decided"]
           /\ UNCHANGED <<named, waiting>>

\* syscall_pipe_read under the pipe lock: take a byte, read end of file, or
\* wait.
ReaderLook ==
    /\ pc["r"] = "look"
    /\ IF buf > 0
         THEN /\ buf' = buf - 1
              /\ got' = got + 1
              /\ pc' = [pc EXCEPT !["r"] = AfterChange("r", "look")]
              /\ waiting' = FALSE
              /\ UNCHANGED <<written, writerOpen, named>>
         ELSE IF ~writerOpen
           THEN /\ pc' = [pc EXCEPT !["r"] = "done"]
                /\ UNCHANGED <<buf, written, got, writerOpen, waiting, named>>
           ELSE /\ MustWait("r")
                /\ UNCHANGED <<buf, written, got, writerOpen>>

\* syscall_pipe_write under the pipe lock: put a byte, or wait for room;
\* after the last byte, close the write end (pipe_end_close).
WriterLook ==
    /\ pc["w"] = "look"
    /\ IF written = ITEMS
         THEN /\ writerOpen' = FALSE
              /\ pc' = [pc EXCEPT !["w"] = AfterChange("w", "done")]
              /\ waiting' = FALSE
              /\ UNCHANGED <<buf, written, got, named>>
         ELSE IF buf < CAP
           THEN /\ buf' = buf + 1
                /\ written' = written + 1
                /\ pc' = [pc EXCEPT !["w"] = AfterChange("w", "look")]
                /\ waiting' = FALSE
                /\ UNCHANGED <<got, writerOpen, named>>
           ELSE /\ MustWait("w")
                /\ UNCHANGED <<buf, written, got, writerOpen>>

\* NAMED_UNDER_LOCK = FALSE only: the name, after the pipe lock is gone.
\* @type: (Str) => Bool;
Name(p) ==
    /\ pc[p] = "decided"
    /\ named' = [named EXCEPT ![p] = TRUE]
    /\ waiting' = TRUE
    /\ pc' = [pc EXCEPT ![p] = "named"]
    /\ UNCHANGED <<buf, written, got, writerOpen>>

\* kernel_process_block_current under the run lock: publish Blocked, or,
\* with RECHECK, rerun the call when a wake already took the name
\* (kernel_process_block_would_miss).
\* @type: (Str) => Bool;
Block(p) ==
    /\ pc[p] = "named"
    /\ pc' = [pc EXCEPT ![p] = IF RECHECK /\ ~named[p] THEN "look" ELSE "asleep"]
    /\ UNCHANGED <<buf, written, got, writerOpen, waiting, named>>

\* kernel_process_pipe_wake under the run lock: every record naming the pipe
\* loses the name, and one Blocked on it looks again.
\* @type: (Str) => Bool;
Walk(p) ==
    /\ pc[p] = "walk"
    /\ named' = [q \in Procs |-> FALSE]
    /\ pc' = [q \in Procs |->
                IF q = p
                  THEN (IF p = "w" /\ ~writerOpen THEN "done" ELSE "look")
                  ELSE IF named[q] /\ pc[q] = "asleep" THEN "look" ELSE pc[q]]
    /\ UNCHANGED <<buf, written, got, writerOpen, waiting>>

\* Both finished: nothing left to do.
Finished ==
    /\ pc["r"] = "done" /\ pc["w"] = "done"
    /\ UNCHANGED vars

Next ==
    \/ ReaderLook
    \/ WriterLook
    \/ \E p \in Procs : Name(p) \/ Block(p) \/ Walk(p)
    \/ Finished

Fairness ==
    /\ WF_vars(ReaderLook)
    /\ WF_vars(WriterLook)
    /\ \A p \in Procs : WF_vars(Name(p)) /\ WF_vars(Block(p)) /\ WF_vars(Walk(p))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ buf \in 0..CAP
    /\ written \in 0..ITEMS
    /\ got \in 0..ITEMS
    /\ \A p \in Procs : pc[p] \in {"look", "decided", "named", "asleep", "walk", "done"}

\* A sleeper beside what it waits for -- a byte or end of file for the
\* reader, room for the writer -- is still named, and the other side is on
\* its way to the walk that wakes it.
NoLostWakeup ==
    /\ (pc["r"] = "asleep" /\ (buf > 0 \/ ~writerOpen))
           => (named["r"] /\ pc["w"] = "walk")
    /\ (pc["w"] = "asleep" /\ buf < CAP)
           => (named["w"] /\ pc["r"] = "walk")

\* Every byte written is read, then end of file.
AllRead == <>(pc["r"] = "done" /\ got = ITEMS)

----------------------------------------------------------------------------
(* Constant initializers for Apalache (TLC reads the .cfg files instead). *)

CInitFixed == NAMED_UNDER_LOCK = TRUE /\ RECHECK = TRUE
CInitUnlocked == NAMED_UNDER_LOCK = FALSE /\ RECHECK = TRUE
CInitNoRecheck == NAMED_UNDER_LOCK = TRUE /\ RECHECK = FALSE

=============================================================================
