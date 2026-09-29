# UART terminal

The maintained platforms expose one local PL011 terminal. Every terminal fd
alias uses the same termios settings and receive line discipline. UART IRQs
run on CPU 0; a reader or writer can run on any admitted CPU. Termios ioctls
migrate to CPU 0 because transmitter drain checks touch device registers.

## Linux ABI and supported settings

`TCGETS` copies the 36-byte Linux arm64 kernel termios structure: four 32-bit
flag words, one line-discipline byte, and nineteen control bytes. It does not
copy libc's larger userspace structure. `TCSETS` applies immediately;
`TCSETSW` waits for terminal output, peer console records and the UART FIFO
to drain; `TCSETSF` additionally discards pending input. Invalid settings
return `EINVAL` before waiting, leave the old settings intact, and work the
same way through fd aliases. Bad user ranges return `EFAULT`.

The initial settings describe the existing raw UART: no input or output
conversion, no canonical buffering, and no kernel echo. Control bytes start
with the usual INTR, QUIT, ERASE, KILL, EOF, START, STOP, SUSP, REPRINT,
WERASE and LNEXT values; VMIN is one and VTIME is zero.

| Flags | Supported behavior |
|---|---|
| ICRNL | Convert received CR to LF, except literal-next input |
| IXON | STOP pauses terminal writes and echo; START resumes them |
| IXOFF | Send STOP at 3072 buffered input bytes, START at 1024 or fewer |
| OPOST, ONLCR | Convert written LF to CR/LF when both are set; count whole input bytes in a short write |
| ICANON | Commit input at LF, EOL, EOF, or EOL2 with IEXTEN; support ERASE and KILL; never erase a committed line |
| ECHO | Echo accepted input through the bounded terminal echo queue |
| ECHOE | Erase the displayed columns, including tabs and caret notation |
| ECHOK, ECHOKE | Echo a kill newline, or erase the killed line with ECHOE, ECHOK and ECHOKE |
| ECHONL | Echo canonical newlines even when ECHO is off |
| ECHOCTL | Show echoed control characters as caret notation, except TAB and LF |
| IEXTEN | Support word erasure at an alphanumeric/underscore boundary, REPRINT and LNEXT in canonical mode |
| ISIG | Generate SIGINT, SIGQUIT and SIGTSTP from INTR, QUIT and SUSP; flush pending terminal input and output and resume IXON-paused output |

The UART is fixed at 115200 baud, eight data bits, no parity and one stop
bit, with CREAD and CLOCAL. Different baud, framing, receive or hardware-flow
settings are rejected. HUPCL is accepted: this local console never asserts
DTR or RTS, so those modem lines are already deasserted at close. It does not
hang up the kernel console or change the UART configuration.

Control bytes can be changed or disabled with zero. Nonzero line disciplines,
VTIME, VSWTC, VDISCARD and reserved control bytes, VMIN other than one, and
other flag bits are rejected. These settings include every attribute that
BusyBox init's `set_sane_term` requests. Unsupported ioctl requests return
`ENOTTY`, valid nonterminal fds return `ENOTTY`, and missing fds return `EBADF`.
`TIOCGWINSZ` returns a fixed 24 rows and 80 columns with zero pixel sizes;
setting a window size and controlling-terminal/job-control ioctls are rejected.

## Reads and signals

A noncanonical read returns one available byte, preserving the existing
VMIN=1, VTIME=0 path. A canonical read returns up to its requested length
from one committed line. EOF commits preceding bytes without copying a NUL;
an EOF at the start of a line makes that read return zero. A quoted LF is
ordinary data until a later delimiter commits it. The ring reserves a slot
for a delimiter so an overlong unfinished line cannot fill it forever.

The last terminal reader's session is the UART foreground group. The process
model currently uses one group per session; it does not implement setpgid or
controlling terminals. INTR and QUIT use the existing default-termination
resource-release path and normalized exit status 128+signal. Signal masks and
synchronous waits apply to generated signals. PID 1 is excluded from terminal
signal delivery. Custom SIGINT/SIGQUIT handlers and core dumps are outside
the maintained signal implementation, as described in `SYSCALLS.md`.

Each group is orphaned while there is only one group per session: no member
has a parent in the same session and a different group. Therefore an unmasked
SIGTSTP with its default disposition is ignored. A blocked SIGTSTP remains
pending and can be consumed by `rt_sigtimedwait`.

## Synchronization and capacity

The process-run lock orders settings, line editing, input consumption,
foreground membership and the transition to a blocked reader. The same lock
orders whole output-chunk admission against settings changes and drain
queries. Changing canonical mode wakes retrying Linux readers when queued
input becomes readable. The internal scalar UART waiter still receives a
real byte directly from the interrupt.

TX paths acquire a single atomic pause word without taking the process-run
lock. Readers publish the desired input-throttle state atomically; CPU 0 sends
the latest request, so a peer that drains the ring cannot leave the sender
stopped indefinitely. Kernel diagnostics and debugger flushes remain available
while terminal output is paused.

CPU 0 owns the 4096-operation echo queue and masks IRQs for every access.
One operation represents a byte, a caret pair, an entire erasure, or CR/LF.
This fits a full canonical line and its kill without spinning inside the RX
interrupt while output is stopped. An operation beyond capacity is rejected
and counted; the boot reports `terminal echo: operations=4096 dropped=N`.
Ordinary user output and peer records wait behind pending echo. Signal flushes
preserve tagged kernel diagnostic bytes while discarding terminal output;
already-transmitted FIFO bytes cannot be recalled.

`linux_user/uart_rx_ring` tests the production ring, settings rejection,
control-byte policy, throttle hysteresis, compact erasure expansion and queue
exhaustion. It compiles the production ONLCR encoder and checks source/wire
counts and whole CR/LF admission at room and staging-buffer boundaries. `/bin/termios` and its host UART scenario exercise the actual EL0
ioctls, echo bytes, editing, EOF, flow control and masked signals on CPUs 0 and
1. The usual QEMU and RPi5 UART driver runs it before the bounded ash command
fixture, while the launching shell waits in the foreground. Respawning
background init actions use `/dev/null` for standard I/O so they cannot reset
the interactive UART or change the probe's settings. The peer-console writer
starts once with UART output; it does not respawn. The existing raw peer-terminal reader still
runs after network integration.
