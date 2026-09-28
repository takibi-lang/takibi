#!/usr/bin/env python3
"""Exercise guarded-fault recovery through a real RPi5 UART BREAK.

Every exit path, including the give-ups, reports the timeline: when the BREAK
was sent, when DDB first prompted, when it said it was continuing, when the
resume command went out, and when its echo came back, each against the one
budget the whole session shares.

That is here because the failure it reports says one word about two different
things. `RPi5 workload did not resume after DDB continue` is reached only when
`ddb: continuing` was already in the capture, so the question is whether the
shell echo was slow or whether it never happened -- whether the budget ran out
mid-round-trip, or the resume command was written into a UART that had just
resumed and was dropped. Those need opposite repairs, and the timeline
separates them: `continuing` late in the budget is the first, `continuing`
early with a long silent wait after it is the second.

The budget was measured rather than assumed. Seven consecutive lane runs on
2026-09-05 all reported the same timeline to a tenth of a second --
`continuing=1.4s resume-echoed=1.6s` of a 20s budget -- so a failure at this
step is roughly eighteen seconds of silence, not a round trip that ran late.
Lengthening the deadline, which is what GitHub issue #509 needed for a QEMU
stall, would therefore not repair this one.

So the resume command is RETRIED instead of written once. A healthy round trip
is 0.2s; a command that draws no echo within RESUME_RETRY_SECONDS is sent
again, bounded by the same budget. That costs a passing run nothing, and it
makes the give-up mean what it says: after several commands and no echo, the
workload really did not resume. `run_kernel_ddb_rpi5_software_driver.py`, the
sibling that drives the same recovery from a software breakpoint and has not
been reported flaky, already requires a shell prompt in the capture before it
types at the resumed shell; this one types on `ddb: continuing` alone.

The rate was NOT reproduced: 0 failures in 7 runs on 2026-09-05, against 2 in
4 on 2026-09-04. A clean 7 happens 13% of the time if the real rate is 1 in
4, and 70% of the time if it is 1 in 20, so the old rate is ruled out and a
low one is not. This retry is therefore not a verified repair of that
intermittent. What IS established is that the deadline is not the cause, and
that a single un-retried write had no recovery path at all.
"""

import argparse
import re
import time

import serial

# The milestones, in the order the session reaches them.
MILESTONES = ("wake-sent", "wake-acked", "break-sent", "first-prompt",
              "continuing", "resume-sent", "resume-echoed")

# A response is useful pacing, but not required: the DDB peer-console
# fixture holds CPU 1's whole output ring until continue. An ash running on
# that CPU consumes input and queues its prompt without answering here.
# The event sequence below, not terminal output, proves input preceded BREAK.
WAKE_RESPONSE_SECONDS = 3.0

# Keep the existing read-only postmortem when there was no response, then
# perform the same guarded-fault, inspection and resume checks as usual.
SILENT_POSTMORTEM_COMMANDS = (b"oops\n", b"intr\n", b"bt\n", b"sched\n",
                              b"current\n", b"ps\n", b"stacks\n",
                              b"events\n")


def wake_preceded_break(text: str) -> bool:
    """Both IRQ events are recorded on CPU 0; compare only that ring's order."""
    wake_sequences = []
    break_sequences = []
    for seq, event, value in re.findall(
        r"^ddb: event seq=(\d+) cpu=0 id=(0x[0-9a-f]+) "
        r"a=(0x[0-9a-f]+) ", text.replace("\r", ""), re.MULTILINE
    ):
        if int(event, 16) == 0x0201 and int(value, 16) == 0x0A:
            wake_sequences.append(int(seq))
        elif int(event, 16) == 0x0101:
            break_sequences.append(int(seq))
    return bool(wake_sequences and break_sequences and
                min(wake_sequences) < min(break_sequences))


# How long a resume command may draw no echo before it is sent again. A
# healthy round trip is 0.2s, so this is generous by an order of magnitude and
# still leaves the 20s budget room for several attempts.
RESUME_RETRY_SECONDS = 2.0


class Timeline:
    """When each milestone happened, in seconds since the session started."""

    def __init__(self, budget: float) -> None:
        self.budget = budget
        self.started = time.monotonic()
        self.at: dict[str, float] = {}
        self.resume_attempts = 0

    def mark(self, name: str) -> None:
        self.at.setdefault(name, time.monotonic() - self.started)

    def elapsed(self) -> float:
        return time.monotonic() - self.started

    def render(self) -> str:
        parts = [
            f"{name}={self.at[name]:.1f}s" if name in self.at
            else f"{name}=never"
            for name in MILESTONES
        ]
        return (f"timeline: {' '.join(parts)} "
                f"resume-attempts={self.resume_attempts} "
                f"(elapsed {self.elapsed():.1f}s of {self.budget:.1f}s)")

    def bail(self, message: str) -> SystemExit:
        return SystemExit(f"{message}\n{self.render()}")


def resumed(normalized: bytes) -> bool:
    """Has the shell run a command since DDB said it was continuing?

    The proof is the command's OUTPUT on a line of its own, after the
    continuing line. It used to be `/ # ddb-resume-ok`, a prompt immediately
    followed by the output -- which held only while the newline that wakes
    the shell was still unconsumed when the BREAK landed. Now that the wake
    is acknowledged first (GitHub issue #519), the shell has already answered
    that newline, so the first command after the resume produces its output
    with no prompt in front of it. The command was running fine; the marker
    was describing a side effect of the race it now avoids.

    Anchored after `ddb: continuing` so nothing earlier in the capture can
    satisfy it. The shell does not echo what is typed at it, so the only
    source of this line is the command having run.

    With or without a prompt in front of it, then. Which one appears is that
    same race -- whether the shell answered the waking newline before the
    BREAK -- and it moved again in #609, when wait4 began to run on a peer
    and the shell's scheduling around the break changed: four-core RPi5
    printed `/ # ddb-resume-ok` nine times while this refused all of them.
    Either form proves the command ran; only the absence of the output
    proves it did not.
    """
    continuing = normalized.find(b"ddb: continuing\n")
    if continuing < 0:
        return False
    tail = normalized[continuing:].replace(b"\x1b[6n", b"")
    return any(line.removeprefix(b"/ # ").removeprefix(b" # ") == b"ddb-resume-ok"
               for line in tail.splitlines())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    timeline = Timeline(args.timeout)
    deadline = time.monotonic() + args.timeout
    received = bytearray()
    prompt_count = 0
    resume_command_sent = False
    last_resume_write = 0.0
    commands = (b"xkfault\n", b"events\n", b"bt\n", b"bt cpu 1\n",
                b"wait\n", b"continue\n")
    with serial.Serial(args.port, 115200, timeout=0.25) as uart, open(
        args.log, "ab"
    ) as log:
        # Generate one newline UART-wake. A visible response can pace BREAK,
        # but the held peer ring may hide it until continue. Always verify
        # the retained IRQ-event order before accepting this exercise.
        uart.reset_input_buffer()
        uart.write(b"\n")
        uart.flush()
        timeline.mark("wake-sent")
        ack_deadline = min(time.monotonic() + WAKE_RESPONSE_SECONDS, deadline)
        while time.monotonic() < ack_deadline:
            chunk = uart.read(4096)
            if chunk:
                received.extend(chunk)
                log.write(chunk)
                log.flush()
                timeline.mark("wake-acked")
                break
        if "wake-acked" not in timeline.at:
            commands = SILENT_POSTMORTEM_COMMANDS + commands
        uart.send_break(0.25)
        timeline.mark("break-sent")
        while time.monotonic() < deadline:
            # The read is what paces this loop, at its 0.25s timeout. An
            # empty read must NOT skip the rest of the body: silence after
            # the resume command is exactly the state the retry below exists
            # for, and a `continue` here would mean the retry could only fire
            # while the shell was already talking.
            chunk = uart.read(4096)
            if chunk:
                received.extend(chunk)
                log.write(chunk)
                log.flush()

            # Evaluated every iteration, not only when a chunk just arrived.
            # The acknowledgement read above can pull the debugger banner in
            # alongside the byte it was waiting for, and gating this on a
            # NEW chunk then leaves a prompt sitting unanswered in a buffer
            # while the session waits for output that has already been sent.
            found = received.count(b"ddb> ")
            if found:
                timeline.mark("first-prompt")
            while prompt_count < found:
                if prompt_count < len(commands):
                    uart.write(commands[prompt_count])
                    uart.flush()
                prompt_count += 1

            normalized = bytes(received).replace(b"\r", b"")
            if resumed(normalized):
                timeline.mark("resume-echoed")
                break
            if b"ddb: continuing\n" in received:
                timeline.mark("continuing")
                # First write, then a resend for as long as no echo comes
                # back. A write into a UART that has only just resumed has no
                # other recovery path, and a resend is indistinguishable from
                # the first command to the shell.
                if (not resume_command_sent
                        or time.monotonic() - last_resume_write
                        >= RESUME_RETRY_SECONDS):
                    uart.write(b"echo ddb-resume-ok\n")
                    uart.flush()
                    last_resume_write = time.monotonic()
                    timeline.resume_attempts += 1
                    timeline.mark("resume-sent")
                    resume_command_sent = True

    text = received.decode("ascii", errors="replace")
    if "oops: fail-stop" in text:
        raise timeline.bail(
            "RPi5 DDB did not resume after guarded fault "
            "(entered fail-stop crash console)"
        )
    if prompt_count == 0:
        raise timeline.bail("RPi5 DDB did not answer the UART BREAK")
    if prompt_count < 2:
        raise timeline.bail(
            "RPi5 DDB did not return to a prompt after guarded fault")
    if "ddb: xk fault address=0x0000000800000000" not in text:
        raise timeline.bail("RPi5 DDB guarded fault was not reported")
    if "ddb: world-stop complete mask=0x000000000000000e" not in text:
        raise timeline.bail(
            "RPi5 DDB did not stop and acknowledge all online peers")
    if "ddb: events cpu=0 count=" not in text:
        raise timeline.bail(
            "RPi5 DDB post-fault inspection command did not complete")
    if not re.search(
        r"^ddb: bt source=cpu cpu=[0-9]+ pid=[0-9]+ "
        r"stack=0x[0-9a-f]+\.\.0x[0-9a-f]+$",
        text.replace("\r", ""),
        re.MULTILINE,
    ):
        raise timeline.bail("RPi5 DDB did not capture a CPU backtrace root")
    if not re.search(
        r"^ddb: bt frame=0 pc=0x[0-9a-f]+ "
        r"boundary=(exception|user|assembly|assembly-bridge)$",
        text.replace("\r", ""),
        re.MULTILINE,
    ):
        raise timeline.bail(
            "RPi5 DDB did not report the interrupted PC boundary")
    if not wake_preceded_break(text):
        raise timeline.bail(
            "RPi5 DDB did not retain a newline UART-wake event before BREAK")
    if "id=0x0000000000000101" not in text:
        raise timeline.bail(
            "RPi5 DDB did not retain the platform UART BREAK event")
    if "damaged=0 overwritten=0" not in text:
        raise timeline.bail(
            "RPi5 DDB diagnostic ring reported damaged/overwritten data")
    # GitHub issue #505: the board's own peer, backtraced from the root it
    # published entering the world-stop pen. QEMU proves the decision; only
    # this lane proves that a real second core, stopped by a real SGI, has a
    # frame the walker can follow.
    if re.search(r"^ddb: bt source=stopped cpu=1 pid=\d+ "
                 r"stack=0x[0-9a-f]+\.\.0x[0-9a-f]+$", text,
                 re.MULTILINE) is None:
        raise timeline.bail("RPi5 DDB did not backtrace the stopped peer")

    # GitHub issue #529. The synthetic topology is a QEMU control; what only
    # this lane can say is that the derivation runs on the board's own
    # snapshot and decodes it the same way -- same header, same trailer, no
    # platform-specific numbers.
    if re.search(r"^ddb: wait current=\d+ state=[a-z-]+ reason=[a-z-]+"
                 r"( queued=\d+( low-water=\d+)?|"
                 r" frame-pending=(yes|no|unknown) "
                 r"connection-pending=(yes|no|unknown))? awaited=[01]$",
                 text, re.MULTILINE) is None:
        raise timeline.bail("RPi5 DDB did not render the wait header")
    if re.search(r"^ddb: wait edges=\d+ blocked=\d+ unknown=\d+ "
                 r"truncated=[01]$", text, re.MULTILINE) is None:
        raise timeline.bail("RPi5 DDB did not render the wait summary")
    if "ddb: continuing\n" not in text:
        raise timeline.bail(
            "RPi5 DDB did not continue after post-fault inspection")
    # GitHub issue #531. The queue was live when the BREAK landed -- this
    # lane's fault is triggered from the resumed shell, long after
    # kernel_log_tx_activate() -- so the resume must put it back. Nothing
    # else on this lane can see it: the boot's own `console: tx spin`
    # measurement is printed before the shell, so a console left spinning
    # from here costs 78.9 us/byte for the rest of the run and fails
    # nothing.
    if "ddb: console tx=queued\n" not in text:
        raise timeline.bail(
            "RPi5 DDB did not restore the console transmit queue on continue")
    # GitHub issue #534. The loader armed this boot's peer console hold, so
    # the peer published one record that core 0 left undrained for this
    # BREAK; it must still be there at entry and reach the wire after
    # `continue`, not before and not never.
    if "ddb: peer console=pending\n" not in text:
        raise timeline.bail(
            "RPi5 DDB did not observe the held peer console record")
    continuing = text.find("ddb: continuing\n")
    delivered = text.find(
        "peer user console: queued before DDB, delivered after continue\n",
        continuing,
    )
    if continuing < 0 or delivered < 0:
        raise timeline.bail(
            "RPi5 peer console record did not follow DDB continue")
    if not resumed(bytes(received).replace(b"\r", b"")):
        raise timeline.bail(
            f"RPi5 workload did not resume after DDB continue: "
            f"{timeline.resume_attempts} resume command(s) went out and no "
            "echo came back")
    print("PASS kernel/rpi5 ddb: guarded fault recovered, inspected, and "
          "resumed")
    print(timeline.render())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
