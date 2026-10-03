---------------------------- MODULE LogReader ----------------------------
EXTENDS Integers

(***************************************************************************)
(* A kernel log read on one CPU while another appends (GitHub issue #612).  *)
(*                                                                         *)
(* One writer -- core 0 -- appends records to a ring of RING slots,        *)
(* overwriting the oldest. Starting a record, it sets that slot's length   *)
(* to 0 and then publishes `started`, the number of records begun. Each   *)
(* byte is stored and then the slot's length is published. Record s lives  *)
(* in slot s % RING.                                                        *)
(*                                                                         *)
(* A reader on another CPU -- syslog(2) on a peer -- takes no lock. It     *)
(* reads `started`, then the record's length, copies that many bytes, and *)
(* then reads `started` again. If the writer has since begun the record that reuses   *)
(* that slot, the copy may mix two records, and the reader drops it and    *)
(* counts it lost instead of returning it.                                 *)
(*                                                                         *)
(* SECOND_CHECK = FALSE skips that second read. TLC must find NoTornRead   *)
(* violated: a returned copy whose bytes came from two different records. *)
(*                                                                         *)
(* The length is not decoration. The first version of this model had the *)
(* reader copy whole slots, and TLC showed the record just begun still     *)
(* holding the bytes of the one it replaces: copied as the new record, and *)
(* with nothing reused since, the check passed it.                         *)
(*                                                                         *)
(* One action per step each side takes, since there is no lock: every      *)
(* store and load is a point where the other side can run.                 *)
(***************************************************************************)

CONSTANTS
    \* @type: Bool;
    SECOND_CHECK

RING == 2        \* slots in the ring
BYTES == 2       \* bytes in a record
RECORDS == 4     \* records the writer begins in all

VARIABLES
    \* @type: Int -> (Int -> Int);
    slot,        \* per slot: per byte, the record that stored it (-1 none)
    \* @type: Int -> Int;
    len,         \* per slot: bytes of its current record published so far
    \* @type: Int;
    started,     \* records the writer has begun and published
    \* @type: Int;
    wbyte,       \* the next byte the writer stores in record started - 1
    \* @type: Str;
    rstate,      \* "idle" | "copying" | "checking" | "done"
    \* @type: Int;
    rrecord,     \* the record the reader is copying
    \* @type: Int;
    rlen,        \* the length it read
    \* @type: Int;
    rbyte,       \* the next byte it copies
    \* @type: Int -> Int;
    copy,        \* per byte: the record its copy came from
    \* @type: Bool;
    tornReturned \* was a copy mixing two records ever returned

vars == <<slot, len, started, wbyte, rstate, rrecord, rlen, rbyte, copy, tornReturned>>

Slots == 0 .. RING - 1
Bytes == 0 .. BYTES - 1

Init ==
    /\ slot = [s \in Slots |-> [b \in Bytes |-> -1]]
    /\ len = [s \in Slots |-> 0]
    /\ rlen = 0
    /\ started = 0
    /\ wbyte = BYTES
    /\ rstate = "idle"
    /\ rrecord = 0
    /\ rbyte = 0
    /\ copy = [b \in Bytes |-> -1]
    /\ tornReturned = FALSE

----------------------------------------------------------------------------
(* The writer *)

\* kernel_log_start_line: the previous record is complete; take the next
\* slot, overwriting the oldest record: its length goes to 0, and then --
\* ordered by the release -- the new count is published.
WriterStart ==
    /\ wbyte = BYTES
    /\ started < RECORDS
    /\ len' = [len EXCEPT ![started % RING] = 0]
    /\ started' = started + 1
    /\ wbyte' = 0
    /\ UNCHANGED <<slot, rstate, rrecord, rlen, rbyte, copy, tornReturned>>

\* kernel_log_capture_retained_byte: one byte of the current record, then --
\* ordered by the release -- its length.
WriterByte ==
    /\ started > 0
    /\ wbyte < BYTES
    /\ slot' = [slot EXCEPT ![(started - 1) % RING][wbyte] = started - 1]
    /\ len' = [len EXCEPT ![(started - 1) % RING] = wbyte + 1]
    /\ wbyte' = wbyte + 1
    /\ UNCHANGED <<started, rstate, rrecord, rlen, rbyte, copy, tornReturned>>

----------------------------------------------------------------------------
(* The reader *)

\* Load `started` and choose a record still in the ring. The last record
\* begun may still be growing; its length says how much of it is there.
ReaderBegin ==
    /\ rstate = "idle"
    /\ started > 0
    /\ \E r \in (IF started > RING THEN started - RING ELSE 0) .. started - 1 :
          /\ rrecord' = r
          /\ rbyte' = 0
          /\ copy' = [b \in Bytes |-> -1]
          /\ rstate' = "length"
    /\ UNCHANGED <<slot, len, started, wbyte, rlen, tornReturned>>

\* Load the record's slot length, with acquire.
ReaderLength ==
    /\ rstate = "length"
    /\ rlen' = len[rrecord % RING]
    /\ rstate' = "copying"
    /\ UNCHANGED <<slot, len, started, wbyte, rrecord, rbyte, copy, tornReturned>>

\* Copy one byte of the chosen record's slot, below the length read.
ReaderByte ==
    /\ rstate = "copying"
    /\ rbyte < rlen
    /\ copy' = [copy EXCEPT ![rbyte] = slot[rrecord % RING][rbyte]]
    /\ rbyte' = rbyte + 1
    /\ UNCHANGED <<slot, len, started, wbyte, rstate, rrecord, rlen, tornReturned>>

ReaderCopied ==
    /\ rstate = "copying"
    /\ rbyte = rlen
    /\ rstate' = "checking"
    /\ UNCHANGED <<slot, len, started, wbyte, rrecord, rlen, rbyte, copy, tornReturned>>

\* Load `started` again. A record whose slot has been reused since is
\* dropped as lost. Without the check, the copy is returned whatever it is.
ReaderCheck ==
    /\ rstate = "checking"
    /\ LET reused == started > rrecord + RING
           returned == ~SECOND_CHECK \/ ~reused
           torn == \E b \in Bytes : copy[b] # -1 /\ copy[b] # rrecord
       IN  tornReturned' = (tornReturned \/ (returned /\ torn))
    /\ rstate' = "done"
    /\ UNCHANGED <<slot, len, started, wbyte, rrecord, rlen, rbyte, copy>>

\* The reader goes round again.
ReaderAgain ==
    /\ rstate = "done"
    /\ rstate' = "idle"
    /\ UNCHANGED <<slot, len, started, wbyte, rrecord, rlen, rbyte, copy, tornReturned>>

Next ==
    \/ WriterStart
    \/ WriterByte
    \/ ReaderBegin
    \/ ReaderLength
    \/ ReaderByte
    \/ ReaderCopied
    \/ ReaderCheck
    \/ ReaderAgain
    \/ (started = RECORDS /\ wbyte = BYTES /\ rstate = "idle" /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ started \in 0 .. RECORDS
    /\ wbyte \in 0 .. BYTES
    /\ rstate \in {"idle", "length", "copying", "checking", "done"}
    /\ rrecord \in 0 .. RECORDS
    /\ rbyte \in 0 .. BYTES
    /\ tornReturned \in BOOLEAN

\* #612's property: no copy the reader returns holds bytes of two records.
NoTornRead == ~tornReturned

----------------------------------------------------------------------------
(* Constant initializers for Apalache. *)

CInitFixed == SECOND_CHECK = TRUE
CInitUnchecked == SECOND_CHECK = FALSE

=============================================================================
