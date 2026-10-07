--------------------------- MODULE WorldStop ---------------------------
(* The shared gate covers pending CPU_ON and generation-scoped world stops.
   A possible participant is reserved BEFORE firmware may start it. A stop
   captures this set under the gate, including uncertain/pending starts.
   Three CPUs and two non-reused generations are bounded evidence only.
   IRQ-open infinitely often does not guarantee a bounded wait succeeds:
   Timeout may always win. Accordingly this model checks safety and bounded
   request resolution, not starvation freedom of arbitrary retry loops. *)
EXTENDS Naturals, FiniteSets
CONSTANTS
    \* @type: Bool;
    FULL_SET,
    \* @type: Bool;
    START_GATE
VARIABLES
    \* @type: Set(Int);
    possible,
    \* @type: Set(Int);
    present,
    \* @type: Int;
    starting,
    \* @type: Str;
    phase,
    \* @type: Int;
    owner,
    \* @type: Int;
    generation,
    \* @type: Int;
    requested,
    \* @type: Set(Int);
    targets,
    \* @type: Int -> Int;
    ack,
    \* @type: Set(Int);
    pen,
    \* @type: Set(Int);
    irqOpen,
    \* @type: Bool;
    badRead

Cpus == 1..3
vars == <<possible, present, starting, phase, owner, generation, requested,
          targets, ack, pen, irqOpen, badRead>>
Init ==
    /\ possible = {1}
    /\ present = {1}
    /\ starting = 0
    /\ phase = "Idle"
    /\ owner = 0
    /\ generation = 0
    /\ requested = 0
    /\ targets = {}
    /\ ack = [c \in Cpus |-> 0]
    /\ pen = {}
    /\ irqOpen = Cpus
    /\ badRead = FALSE

StartReserve(c) ==
    /\ c \in Cpus \ present
    /\ starting = 0
    /\ (phase = "Idle" \/ (~START_GATE /\ phase = "Complete"))
    /\ possible' = possible \cup {c}
    /\ starting' = c
    /\ phase' = IF phase = "Idle" THEN "Starting" ELSE phase
    /\ UNCHANGED <<present, owner, generation, requested, targets, ack,
                   pen, irqOpen, badRead>>

(* Firmware acceptance can expose the CPU before its Takibi handshake. *)
StartFirmware ==
    /\ starting # 0
    /\ present' = present \cup {starting}
    /\ UNCHANGED <<possible, starting, phase, owner, generation, requested,
                   targets, ack, pen, irqOpen, badRead>>

(* A pending accepted CPU can arrive even after CPU_ON returned. *)
CpuArrive(c) ==
    /\ c \in possible \ present
    /\ present' = present \cup {c}
    /\ UNCHANGED <<possible, starting, phase, owner, generation, requested,
                   targets, ack, pen, irqOpen, badRead>>

StartFinish ==
    /\ starting # 0
    /\ starting' = 0
    /\ phase' = IF phase = "Starting" THEN "Idle" ELSE phase
    /\ UNCHANGED <<possible, present, owner, generation, requested, targets,
                   ack, pen, irqOpen, badRead>>

(* Only definitive absence removes a NEW reservation. *)
StartAbsent ==
    /\ starting # 0
    /\ starting \notin present
    /\ possible' = possible \ {starting}
    /\ starting' = 0
    /\ phase' = IF phase = "Starting" THEN "Idle" ELSE phase
    /\ UNCHANGED <<present, owner, generation, requested, targets, ack,
                   pen, irqOpen, badRead>>

Claim(c) ==
    /\ phase = "Idle"
    /\ c \in present \ pen
    /\ generation < 2
    /\ owner' = c
    /\ phase' = "Claimed"
    /\ UNCHANGED <<possible, present, starting, generation, requested,
                   targets, ack, pen, irqOpen, badRead>>

Publish ==
    /\ phase = "Claimed"
    /\ generation' = generation + 1
    /\ requested' = generation + 1
    /\ targets' = IF FULL_SET THEN possible \ {owner} ELSE {}
    /\ phase' = "Waiting"
    /\ UNCHANGED <<possible, present, starting, owner, ack, pen, irqOpen, badRead>>

Ack(c) ==
    /\ requested # 0
    /\ c \in present \cap irqOpen
    /\ c # owner
    /\ c \notin pen
    /\ ack' = [ack EXCEPT ![c] = requested]
    /\ pen' = pen \cup {c}
    /\ UNCHANGED <<possible, present, starting, phase, owner, generation,
                   requested, targets, irqOpen, badRead>>

Complete ==
    /\ phase = "Waiting"
    /\ \A c \in targets : ack[c] = requested
    /\ phase' = "Complete"
    /\ UNCHANGED <<possible, present, starting, owner, generation, requested,
                   targets, ack, pen, irqOpen, badRead>>

Timeout ==
    /\ phase = "Waiting"
    /\ phase' = "Partial"
    /\ UNCHANGED <<possible, present, starting, owner, generation, requested,
                   targets, ack, pen, irqOpen, badRead>>

Release ==
    /\ phase \in {"Complete", "Partial"}
    /\ starting = 0
    /\ phase' = "Idle"
    /\ requested' = 0
    /\ owner' = 0
    /\ UNCHANGED <<possible, present, starting, generation, targets, ack,
                   pen, irqOpen, badRead>>

PenExit(c) ==
    /\ c \in pen
    /\ ack[c] # requested
    /\ pen' = pen \ {c}
    /\ ack' = [ack EXCEPT ![c] = 0]
    /\ UNCHANGED <<possible, present, starting, phase, owner, generation,
                   requested, targets, irqOpen, badRead>>

ToggleIrq(c) ==
    /\ c \in present \ pen
    /\ irqOpen' = IF c \in irqOpen THEN irqOpen \ {c} ELSE irqOpen \cup {c}
    /\ UNCHANGED <<possible, present, starting, phase, owner, generation,
                   requested, targets, ack, pen, badRead>>

Read ==
    /\ phase = "Complete"
    /\ badRead' = (badRead \/ ~(present \subseteq (pen \cup {owner})))
    /\ UNCHANGED <<possible, present, starting, phase, owner, generation,
                   requested, targets, ack, pen, irqOpen>>

Next ==
    \/ \E c \in Cpus : StartReserve(c) \/ CpuArrive(c) \/ Claim(c) \/ Ack(c) \/ PenExit(c) \/ ToggleIrq(c)
    \/ StartFirmware \/ StartFinish \/ StartAbsent \/ Publish \/ Complete
    \/ Timeout \/ Release \/ Read
Spec == Init /\ [][Next]_vars /\ WF_vars(Complete) /\ WF_vars(Timeout)

TypeOK ==
    /\ possible \subseteq Cpus /\ present \subseteq possible
    /\ starting \in 0..3 /\ owner \in 0..3
    /\ phase \in {"Idle", "Starting", "Claimed", "Waiting", "Partial", "Complete"}
    /\ generation \in 0..2 /\ requested \in 0..2
    /\ targets \subseteq Cpus /\ pen \subseteq present /\ irqOpen \subseteq Cpus
    /\ ack \in [Cpus -> 0..2] /\ badRead \in BOOLEAN
NoUnstoppedRead == ~badRead
RequestResolves == (phase = "Waiting") ~> (phase # "Waiting")
CInitFixed == FULL_SET = TRUE /\ START_GATE = TRUE
CInitSubset == FULL_SET = FALSE /\ START_GATE = TRUE
CInitUngatedStart == FULL_SET = TRUE /\ START_GATE = FALSE
=============================================================================
