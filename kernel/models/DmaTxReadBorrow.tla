------------------------- MODULE DmaTxReadBorrow -------------------------
(***************************************************************************)
(* Cache visibility of one transmit buffer while the device reads it      *)
(* (#740, the TxPosted read borrow). DmaCacheVisibility.tla checks the    *)
(* receive direction; this model checks the transmit one, and whether the *)
(* CPU may READ the buffer while the device still owns it for reading,    *)
(* which is what a TCP retransmit queue holding a TxPosted owner needs.   *)
(*                                                                         *)
(* Same hardware assumptions as DmaCacheVisibility.tla: CPU caches are     *)
(* coherent with each other, not with the device; any core may            *)
(* speculatively fill a clean copy or evict a line at any time; DC CVAC   *)
(* by VA writes a dirty line back to memory in every Inner Shareable      *)
(* cache and leaves it clean, and the DSB after it completes that before  *)
(* the doorbell. The device reads memory only, never a CPU cache.         *)
(*                                                                         *)
(* FAULT 0 is the generated tx lowering with a read-only borrow while     *)
(* posted. FAULT 1 also lets the CPU write while posted (no write          *)
(* accessor exists for a device state; this shows why). FAULT 2 drops the *)
(* clean before the doorbell.                                              *)
(***************************************************************************)

CONSTANTS
    \* @type: Int;
    FAULT

Cpus == {0, 1}

VARIABLES
    \* @type: Str;
    phase,       \* "Cpu" (Filled/Free), "Posted" (TxPosted), "Done"
    \* @type: Int -> Str;
    lst,         \* per-core line state: "I", "C", "D"
    \* @type: Int -> Str;
    lval,        \* per-core line contents: "Init", "A", "B"
    \* @type: Str;
    mem,
    \* @type: Str;
    truth,       \* ghost: what the CPU last wrote
    \* @type: Str;
    sent,        \* ghost: the contents at the doorbell, what must go out
    \* @type: Bool;
    cleaned,
    \* @type: Bool;
    badDeviceRead,  \* the device read something other than what was posted
    \* @type: Bool;
    badCpuRead      \* a CPU read returned something other than truth

vars == <<phase, lst, lval, mem, truth, sent, cleaned, badDeviceRead, badCpuRead>>

Vals == {"Init", "A", "B"}

Init ==
    /\ phase = "Cpu"
    /\ lst = [c \in Cpus |-> "I"]
    /\ lval = [c \in Cpus |-> "Init"]
    /\ mem = "Init"
    /\ truth = "Init"
    /\ sent = "Init"
    /\ cleaned = FALSE
    /\ badDeviceRead = FALSE
    /\ badCpuRead = FALSE

(* ---- the hardware environment ---- *)

SpecFill(c) ==
    /\ lst[c] = "I"
    /\ \/ \E o \in Cpus :
            /\ lst[o] = "D"
            /\ lst' = [lst EXCEPT ![o] = "C", ![c] = "C"]
            /\ lval' = [lval EXCEPT ![c] = lval[o]]
            /\ mem' = lval[o]
       \/ /\ \A o \in Cpus : lst[o] # "D"
          /\ lst' = [lst EXCEPT ![c] = "C"]
          /\ lval' = [lval EXCEPT ![c] = mem]
          /\ UNCHANGED mem
    /\ UNCHANGED <<phase, truth, sent, cleaned, badDeviceRead, badCpuRead>>

Evict(c) ==
    /\ lst[c] # "I"
    /\ lst' = [lst EXCEPT ![c] = "I"]
    /\ IF lst[c] = "D" THEN mem' = lval[c] ELSE UNCHANGED mem
    /\ UNCHANGED <<phase, lval, truth, sent, cleaned, badDeviceRead, badCpuRead>>

(* ---- the owner ---- *)

(* A write through the Filled/Free owner (P_S_write), on any core. *)
CpuWrite(c, v) ==
    /\ \/ phase \in {"Cpu", "Done"}
       \/ FAULT = 1 /\ phase = "Posted"
    /\ lst' = [o \in Cpus |-> IF o = c THEN "D" ELSE "I"]
    /\ lval' = [lval EXCEPT ![c] = v]
    /\ truth' = v
    /\ cleaned' = FALSE
    /\ UNCHANGED <<phase, mem, sent, badDeviceRead, badCpuRead>>

ReadValue(c) ==
    IF lst[c] # "I" THEN lval[c]
    ELSE IF \E o \in Cpus : lst[o] = "D"
         THEN lval[IF lst[0] = "D" THEN 0 ELSE 1]
         ELSE mem

(* A read through the owner: P_S_read in a CPU state, and the read-only *)
(* borrow in TxPosted.                                                    *)
CpuRead(c) ==
    /\ phase \in {"Cpu", "Posted", "Done"}
    /\ badCpuRead' = (badCpuRead \/ ReadValue(c) # truth)
    /\ UNCHANGED <<phase, lst, lval, mem, truth, sent, cleaned, badDeviceRead>>

(* The publishing edge's DC CVAC + DSB over the region. *)
Clean ==
    /\ phase = "Cpu"
    /\ FAULT # 2
    /\ mem' = IF \E o \in Cpus : lst[o] = "D"
              THEN lval[IF lst[0] = "D" THEN 0 ELSE 1] ELSE mem
    /\ lst' = [o \in Cpus |-> IF lst[o] = "D" THEN "C" ELSE lst[o]]
    /\ cleaned' = TRUE
    /\ UNCHANGED <<phase, lval, truth, sent, badDeviceRead, badCpuRead>>

(* The state change and the doorbell. *)
Post ==
    /\ phase = "Cpu"
    /\ (cleaned \/ FAULT = 2)
    /\ phase' = "Posted"
    /\ sent' = truth
    /\ UNCHANGED <<lst, lval, mem, truth, cleaned, badDeviceRead, badCpuRead>>

(* The device reads memory, as often as it likes while posted. *)
DeviceRead ==
    /\ phase = "Posted"
    /\ badDeviceRead' = (badDeviceRead \/ mem # sent)
    /\ UNCHANGED <<phase, lst, lval, mem, truth, sent, cleaned, badCpuRead>>

(* An observed completion: the owner is a CPU state again. *)
Complete ==
    /\ phase = "Posted"
    /\ phase' = "Done"
    /\ UNCHANGED <<lst, lval, mem, truth, sent, cleaned, badDeviceRead, badCpuRead>>

Next ==
    \/ \E c \in Cpus : SpecFill(c) \/ Evict(c) \/ CpuRead(c)
    \/ \E c \in Cpus, v \in {"A", "B"} : CpuWrite(c, v)
    \/ Clean
    \/ Post
    \/ DeviceRead
    \/ Complete

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"Cpu", "Posted", "Done"}
    /\ \A c \in Cpus : lst[c] \in {"I", "C", "D"} /\ lval[c] \in Vals
    /\ mem \in Vals /\ truth \in Vals /\ sent \in Vals

CoherentCaches ==
    \A c \in Cpus : lst[c] = "D" => \A o \in Cpus : o # c => lst[o] = "I"

(* The device transmits what the CPU had written at the doorbell. *)
DeviceReadsPosted == ~badDeviceRead

(* A CPU read, the borrow while posted included, returns the latest write. *)
ReadsCurrent == ~badCpuRead

Safety ==
    /\ TypeOK
    /\ CoherentCaches
    /\ DeviceReadsPosted
    /\ ReadsCurrent

CInitFixed == FAULT = 0
CInitWriteWhilePosted == FAULT = 1
CInitNoClean == FAULT = 2
=============================================================================
