------------------------ MODULE DmaCacheVisibility ------------------------
(***************************************************************************)
(* Cache visibility of one fixed receive allocation across its ownership  *)
(* handoffs (#625). FixedDmaOwnership.tla checks who holds authority; this *)
(* model checks what a CPU actually reads once it holds it. It keeps the  *)
(* data: per-core cache lines, the backing memory, the device's write and *)
(* the prepare / completion / finish sequence of dma_begin_rx and         *)
(* dma_finish_owned_rx as the AArch64 lowering emits it.                   *)
(*                                                                         *)
(* One cache line stands for the allocation: every line of it is          *)
(* maintained by the same loop and the dma_fixed placement rule keeps any *)
(* other object out of its lines.                                          *)
(*                                                                         *)
(* Hardware assumptions, stated as the enabling conditions of actions and  *)
(* not as properties (kernel/models/README.md lists their sources):       *)
(*   - CPU caches are coherent with each other, not with the device. Any  *)
(*     core may speculatively fill a clean copy, or evict a line, at any   *)
(*     time, whoever holds authority (SpecFill, Evict).                    *)
(*   - DC IVAC by VA reaches every core's cache in the Inner Shareable    *)
(*     domain; it discards a dirty line or may write it back first.       *)
(*   - DSB completes earlier cache maintenance before later instructions, *)
(*     and orders it after earlier loads (the completion poll).           *)
(*   - The device's data is in memory before its completion event can be  *)
(*     observed, and a confirmed reset ends its writes.                    *)
(*                                                                         *)
(* FAULT selects the variant: 0 is the maintained lowering, each other    *)
(* value removes one synchronization step or one ordering of it.           *)
(***************************************************************************)

CONSTANTS
    \* @type: Int;
    FAULT

Cpus == {0, 1}

VARIABLES
    \* @type: Str;
    phase,       \* holder's program point: "Cpu" "Preparing" "Submitted"
                 \* "Observed" "TimedOut" "Reset" "Retained" "After"
    \* @type: Int;
    holder,      \* the core that holds the allocation's authority
    \* @type: Int -> Str;
    lst,         \* per-core line state: "I" invalid, "C" clean, "D" dirty
    \* @type: Int -> Str;
    lval,        \* per-core line contents: "Init" "CpuW" "Dev"
    \* @type: Str;
    mem,         \* backing memory at the point of coherence
    \* @type: Str;
    truth,       \* ghost: the latest defined contents, "Undef" while none
    \* @type: Bool;
    deviceActive,
    \* @type: Bool;
    completed,   \* the device wrote its completion event
    \* @type: Bool;
    prepInv,     \* the prepare invalidate is performed (or omitted)
    \* @type: Bool;
    finInv,      \* the finish invalidate is performed
    \* @type: Bool;
    badRead,     \* a CPU read returned something other than truth
    \* @type: Bool;
    lost,        \* stale CPU data overwrote device data before finish
    \* @type: Bool;
    readActive   \* a CPU read while the device could still write

vars == <<phase, holder, lst, lval, mem, truth, deviceActive, completed,
          prepInv, finInv, badRead, lost, readActive>>

Vals == {"Init", "CpuW", "Dev"}

Init ==
    /\ phase = "Cpu"
    /\ holder = 0
    /\ lst = [c \in Cpus |-> "I"]
    /\ lval = [c \in Cpus |-> "Init"]
    /\ mem = "Init"
    /\ truth = "Init"
    /\ deviceActive = FALSE
    /\ completed = FALSE
    /\ prepInv = FALSE
    /\ finInv = FALSE
    /\ badRead = FALSE
    /\ lost = FALSE
    /\ readActive = FALSE

(* A write-back of v that replaces device data while CPU authority has not *)
(* been returned by a finish.                                              *)
\* @type: Str => Bool;
LostIf(v) == lost \/ (mem = "Dev" /\ v # "Dev" /\ phase # "After")

(* ---- the hardware environment: coherent CPU caches ---- *)

SpecFill(c) ==
    /\ lst[c] = "I"
    /\ \/ \E o \in Cpus :
            /\ lst[o] = "D"
            /\ lst' = [lst EXCEPT ![o] = "C", ![c] = "C"]
            /\ lval' = [lval EXCEPT ![c] = lval[o]]
            /\ mem' = lval[o]
            /\ lost' = LostIf(lval[o])
       \/ /\ \A o \in Cpus : lst[o] # "D"
          /\ lst' = [lst EXCEPT ![c] = "C"]
          /\ lval' = [lval EXCEPT ![c] = mem]
          /\ UNCHANGED <<mem, lost>>
    /\ UNCHANGED <<phase, holder, truth, deviceActive, completed, prepInv,
                   finInv, badRead, readActive>>

Evict(c) ==
    /\ lst[c] # "I"
    /\ lst' = [lst EXCEPT ![c] = "I"]
    /\ IF lst[c] = "D"
       THEN mem' = lval[c] /\ lost' = LostIf(lval[c])
       ELSE UNCHANGED <<mem, lost>>
    /\ UNCHANGED <<phase, holder, lval, truth, deviceActive, completed,
                   prepInv, finInv, badRead, readActive>>

(* DC IVAC over the allocation, issued by the holder. FAULT 5 confines it *)
(* to the issuing core, as a set/way or core-local operation would.       *)
Invalidate ==
    LET targets == IF FAULT = 5 THEN {holder} ELSE Cpus IN
    /\ lst' = [o \in Cpus |-> IF o \in targets THEN "I" ELSE lst[o]]
    /\ \/ \E o \in targets :
            /\ lst[o] = "D"
            /\ mem' = lval[o]
            /\ lost' = LostIf(lval[o])
       \/ UNCHANGED <<mem, lost>>

(* ---- the device ---- *)

DeviceWrite ==
    /\ deviceActive
    /\ ~(mem = "Dev" /\ truth = "Dev")
    /\ mem' = "Dev"
    /\ truth' = "Dev"
    /\ UNCHANGED <<phase, holder, lst, lval, deviceActive, completed,
                   prepInv, finInv, badRead, lost, readActive>>

DeviceComplete ==
    /\ deviceActive
    /\ ~completed
    /\ deviceActive' = FALSE
    /\ completed' = TRUE
    /\ UNCHANGED <<phase, holder, lst, lval, mem, truth, prepInv, finInv,
                   badRead, lost, readActive>>

(* ---- the token holder: the kernel's receive sequence ---- *)

(* A CPU access through dma_cpu_ptr while the holder has CPU authority. *)
CpuWrite ==
    /\ phase \in {"Cpu", "After"}
    /\ lst' = [o \in Cpus |-> IF o = holder THEN "D" ELSE "I"]
    /\ lval' = [lval EXCEPT ![holder] = "CpuW"]
    /\ truth' = "CpuW"
    /\ UNCHANGED <<phase, holder, mem, deviceActive, completed, prepInv,
                   finInv, badRead, lost, readActive>>

ReadValue ==
    IF lst[holder] # "I" THEN lval[holder]
    ELSE IF \E o \in Cpus : lst[o] = "D"
         THEN lval[IF lst[0] = "D" THEN 0 ELSE 1]
         ELSE mem

CpuRead ==
    /\ phase \in {"Cpu", "After"}
    /\ badRead' = (badRead \/ (truth # "Undef" /\ ReadValue # truth))
    /\ readActive' = (readActive \/ deviceActive)
    /\ UNCHANGED <<phase, holder, lst, lval, mem, truth, deviceActive,
                   completed, prepInv, finInv, lost>>

(* The owner-slot put on one core and the take on another; the mutex and  *)
(* the finish's completed DSB order the maintenance before the take.      *)
Handoff ==
    /\ \/ phase = "Cpu"
       \/ phase = "After" /\ (finInv \/ FAULT # 4)
    /\ \E c \in Cpus : c # holder /\ holder' = c
    /\ UNCHANGED <<phase, lst, lval, mem, truth, deviceActive, completed,
                   prepInv, finInv, badRead, lost, readActive>>

(* dma_begin_rx consumes the CPU token: the contents become undefined.    *)
BeginRx ==
    /\ phase = "Cpu"
    /\ phase' = "Preparing"
    /\ prepInv' = (FAULT = 1)
    /\ truth' = "Undef"
    /\ UNCHANGED <<holder, lst, lval, mem, deviceActive, completed, finInv,
                   badRead, lost, readActive>>

(* dma_prepare_rx: DC IVAC over the range. FAULT 6 drops the trailing     *)
(* DSB, so the invalidate may be performed after the doorbell.            *)
PrepareInvalidate ==
    /\ ~prepInv
    /\ (phase = "Preparing" \/ (FAULT = 6 /\ phase = "Submitted"))
    /\ Invalidate
    /\ prepInv' = TRUE
    /\ UNCHANGED <<phase, holder, lval, truth, deviceActive, completed,
                   finInv, badRead, readActive>>

(* DSB SY, then the descriptor and the doorbell: the device may write.    *)
Submit ==
    /\ phase = "Preparing"
    /\ (prepInv \/ FAULT = 6)
    /\ phase' = "Submitted"
    /\ deviceActive' = TRUE
    /\ UNCHANGED <<holder, lst, lval, mem, truth, completed, prepInv, finInv,
                   badRead, lost, readActive>>

(* usb_await_event returns the final Transfer Event. Its poll's DSB has    *)
(* completed the prepare maintenance.                                     *)
ObserveCompletion ==
    /\ phase = "Submitted"
    /\ prepInv
    /\ completed
    /\ phase' = "Observed"
    /\ UNCHANGED <<holder, lst, lval, mem, truth, deviceActive, completed,
                   prepInv, finInv, badRead, lost, readActive>>

Timeout ==
    /\ phase = "Submitted"
    /\ prepInv
    /\ phase' = "TimedOut"
    /\ UNCHANGED <<holder, lst, lval, mem, truth, deviceActive, completed,
                   prepInv, finInv, badRead, lost, readActive>>

ConfirmReset ==
    /\ phase = "TimedOut"
    /\ phase' = "Reset"
    /\ deviceActive' = FALSE
    /\ UNCHANGED <<holder, lst, lval, mem, truth, completed, prepInv, finInv,
                   badRead, lost, readActive>>

(* The Device token goes back into the slot; no CPU access follows.      *)
ResetFailed ==
    /\ phase = "TimedOut"
    /\ phase' = "Retained"
    /\ UNCHANGED <<holder, lst, lval, mem, truth, deviceActive, completed,
                   prepInv, finInv, badRead, lost, readActive>>

(* dma_finish_rx: DSB SY; DC IVAC; DSB ISH; ISB; DSB SY. FAULT 2 omits    *)
(* the invalidate; FAULT 3 drops the leading DSB, so the invalidate may be *)
(* performed before the completion is observed; FAULT 4 drops the         *)
(* trailing barriers, so a read may be performed before the invalidate.   *)
FinishInvalidate ==
    /\ ~finInv
    /\ FAULT # 2
    /\ \/ phase \in {"Observed", "Reset"}
       \/ FAULT = 3 /\ phase \in {"Submitted", "TimedOut"}
       \/ FAULT = 4 /\ phase = "After"
    /\ Invalidate
    /\ finInv' = TRUE
    /\ UNCHANGED <<phase, holder, lval, truth, deviceActive, completed,
                   prepInv, badRead, readActive>>

Finish ==
    /\ phase \in {"Observed", "Reset"}
    /\ (finInv \/ FAULT \in {2, 4})
    /\ phase' = "After"
    /\ UNCHANGED <<holder, lst, lval, mem, truth, deviceActive, completed,
                   prepInv, finInv, badRead, lost, readActive>>

Next ==
    \/ \E c \in Cpus : SpecFill(c) \/ Evict(c)
    \/ DeviceWrite
    \/ DeviceComplete
    \/ CpuWrite
    \/ CpuRead
    \/ Handoff
    \/ BeginRx
    \/ PrepareInvalidate
    \/ Submit
    \/ ObserveCompletion
    \/ Timeout
    \/ ConfirmReset
    \/ ResetFailed
    \/ FinishInvalidate
    \/ Finish

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"Cpu", "Preparing", "Submitted", "Observed", "TimedOut",
                  "Reset", "Retained", "After"}
    /\ holder \in Cpus
    /\ \A c \in Cpus : lst[c] \in {"I", "C", "D"} /\ lval[c] \in Vals
    /\ mem \in Vals
    /\ truth \in Vals \union {"Undef"}

(* Hardware coherence between cores: a dirty line is the only copy.       *)
CoherentCaches ==
    \A c \in Cpus : lst[c] = "D" => \A o \in Cpus : o # c => lst[o] = "I"

(* A permitted read after a justified handoff observes the latest data,   *)
(* the completed device data included.                                    *)
ReadsCurrent == ~badRead

(* CPU dirty data never overwrites device data before the finish.         *)
DeviceDataKept == ~lost

(* Composition with FixedDmaOwnership: reads happen only with authority.  *)
NoReadWhileDeviceActive == ~readActive

Safety ==
    /\ TypeOK
    /\ CoherentCaches
    /\ ReadsCurrent
    /\ DeviceDataKept
    /\ NoReadWhileDeviceActive

CInitFixed == FAULT = 0
CInitNoPrepare == FAULT = 1
CInitNoFinish == FAULT = 2
CInitEarlyInvalidate == FAULT = 3
CInitLateRead == FAULT = 4
CInitLocalInvalidate == FAULT = 5
CInitUnpublished == FAULT = 6
=============================================================================
