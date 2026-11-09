# Reverted race633 phase-timeout evidence

This curated host fixture comes from failed land source dc1e69ef on
2026-11-09, preserved unchanged in the archive named by provenance.json.
The provenance records original and curated SHA256 values. The failure log
and await row are copied unchanged. The transcript drops the boot prefix,
normalizes CR and the cursor query, and retains the one command through the
postmortem and terminal shutdown. The original archive remains authoritative.

The driver requested churn.sh 100. There is no heartbeat within that workload:
the existing script prints one every 500 rounds. The actual wait observed
120.22729234899452 seconds against a 120-second deadline. Resync answered True;
this is the phase-timeout case of the settled QEMU timing policy, not its
resync case. A DDB snapshot includes echo churn80 and Running/Constructing
processes. Neither that snapshot nor this policy classification proves
continued progress, rules out a deadlock, or fixes a kernel defect.

The host classifier requires this single phase and its last unresolved await,
binds the timeout and heartbeat count, and refuses early EOF or missing,
malformed or ambiguous evidence. Kernel faults and unexpected functional
verdicts still refuse recording. Transport errors before the completed
postmortem refuse too. Only the exact saved RX socket-close traceback and
expected QEMU SIGTERM after the final diagnostic prompt are treated as
teardown; unrelated late errors still refuse.

The shell runner invokes this classification only for reverted 633 churn
without the required negative signature. A present signature still takes the
original signature/exit/reap/wait4 trace validation. The heartbeat cadence,
deadlines, kernel images, RPi5 timing verdicts and lane inventory are unchanged.
