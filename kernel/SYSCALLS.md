# Syscall support matrix

Every syscall number `kernel_syscall_dispatch` (`kernel/kernel/syscall.tkb`)
recognizes, what it actually does, and why. Anything not listed here falls
through to the final `return (1, LINUX_ENOSYS);` and is Unsupported by
design. This file exists so that state is documented rather than silently
true.

Reached-by-BusyBox column reflects the real, traced integration this kernel
runs: pinned Alpine `busybox-static`/`busybox-extras` 1.37.0-r31 (ash +
`httpd -f -p 8080 -h /`) dynamically linked against pinned `musl` 1.2.6-r2
(see `Makefile`'s `KERNEL_BUSYBOX_URL`/`KERNEL_BUSYBOX_EXTRAS_URL`/
`KERNEL_MUSL_URL`).

| # | name | status | notes |
|---|------|--------|-------|
| 17 | getcwd | Implemented | this kernel has exactly one real directory (`/`); always returns it. Returns the real byte count written (matching the raw syscall's own contract, distinct from the POSIX library wrapper's buffer-pointer return) -- previously returned the buffer address instead, never caught because no scenario called it before the `sh -c` scenario did |
| 24 | dup3 | Implemented | accepted-fd -> stdin/stdout aliasing only, matching the traced daemon child's own shape |
| 49 | chdir | Implemented | accepts `/` and `.`, keeping the one real cwd at the ext2 root; other paths return `ENOENT` |
| 56 | openat | Implemented | generic NUL-terminated absolute pathname lookup, plus relative lookup from an ext2 directory FD; opening a directory returns a directory FD. The read-only `/proc`, `/proc/<pid>`, `/proc/<pid>/stat`, and `/proc/<pid>/cmdline` nodes are virtual and bypass ext2 lookup |
| 57 | close | Implemented | |
| 61 | getdents64 | Implemented | enumerates ext2 directory records from the direct-block directory limit and PID-ordered virtual `/proc` entries into Linux `linux_dirent64` records, with 8-byte alignment, shared FD offsets across `dup`/`fork`, EOF as zero, and `EINVAL` for a buffer too small for the first record |
| 63 | read | Implemented | connected-socket, ext2-file, bounded procfs-file, and UART-fallback paths, all through the typed user-memory boundary (`kernel/mm/user_memory.tkb`); an empty UART RX path blocks and wakes on received input, as exercised by the foreground interactive ash REPL |
| 64 | write | Implemented | same three paths as `read`, plus the inetd-response path |
| 65 | readv | Partial | fd 3 (ext2 file) only, via a standalone segment helper not shared with `read`(64)'s TCP/inetd branches. Each iovec entry validated and copied individually through the user-memory boundary (`struct packed Iovec`, `IOV_MAX`-bounded, `checked_mul_usize`/`checked_add_usize`-guarded array-length and running-total arithmetic). Connected-TCP and inetd-mode fds are not supported |
| 66 | writev | Partial | fd 1/2 (UART) only -- same scoping and same fd-kind gap as `readv` above |
| 71 | sendfile | Implemented | fd 3 (ext2 file) -> fd 1/2 (UART) only, offset must be 0 |
| 73 | ppoll | Partial | real pollfd array validation (`struct packed Pollfd`, `POLL_MAX`-bounded) and real per-fd readiness (UART RX pending, connected-TCP buffered data). Really blocks and wakes on UART RX for exactly one shape: `nfds == 1`, fd 0, `POLLIN` requested, nothing ready, NULL timeout and NULL sigmask -- the shape BusyBox ash's `read` builtin uses. Every other shape returns current readiness immediately, so a non-NULL timeout is never armed and no multi-fd wait exists |
| 79 | newfstatat | Implemented | generic ext2 pathname lookup, including relative lookup from a directory FD, plus fixed asm-generic AArch64 `stat` fields for ext2 and virtual procfs files/directories. Proc process-directory ownership is root/root, matching the kernel's current always-root identity model |
| 93/94 | exit/exit_group | Implemented | real child-vs-parent teardown via the process/fd/VM-clone machinery |
| 96 | set_tid_address | Implemented | returns the real current pid (single-threaded-per-process model) |
| 103 | setitimer | Partial | previous timer is honestly zeroed; no real itimer is armed (this kernel's bounded single-request integration scope never needs `SIGALRM` to actually fire) |
| 113 | clock_gettime | Implemented | fixed epoch-ish timestamp; sufficient for BusyBox httpd's own use |
| 116 | syslog | Partial | Linux `SYSLOG_ACTION_SIZE_BUFFER` (10) and non-destructive `SYSLOG_ACTION_READ_ALL` (3), the exact pair musl `klogctl()` uses for the pinned BusyBox `dmesg` applet. Returns a bounded snapshot of the retained kernel text ring with fixed-width monotonic timestamps. Console-level control, destructive read/clear, blocking reads, `/dev/kmsg`, and unprivileged-access policy are not implemented; unsupported actions return `EINVAL` rather than false success |
| 134 | rt_sigaction | Partial | `signum` validated (`EINVAL` for 0/`SIGKILL`/`SIGSTOP`); non-null `oldact` is validated and zero-filled via the user-memory boundary instead of left uninitialized; no real signal delivery exists, so an installed handler is never actually invoked (the false-success audit recorded why this is safe against the real traced calls: `signal(SIGPIPE\|SIGALRM\|SIGCHLD\|SIGHUP, ...)`, none of which check the return value) |
| 135 | rt_sigprocmask | Implemented | previous mask is honestly zeroed |
| 160 | uname | Implemented | real `struct utsname` reply via the user-memory boundary (`sysname="Linux"`, `nodename="takibi"`, `release="6.1.0-takibi"`, `version="#1"`, `machine="aarch64"`), zero-filled scratch buffer first so no uninitialized kernel memory reaches userspace |
| 172 | getpid | Implemented | |
| 173 | getppid | Implemented | always returns 0; a real parent link exists (`scheduled_process_parent`) but nothing traced needs a real ppid, so it is not wired up |
| 174-177 | getuid/geteuid/getgid/getegid | Implemented | return 0 (always-root model) |
| 178 | gettid | Implemented | returns the real current pid |
| 179 | sysinfo | Partial | writes a zero-filled Linux aarch64 `struct sysinfo` with real generic-counter uptime; other accounting fields remain zero because the pinned BusyBox `ps` consumer uses only uptime |
| 198 | socket | Implemented | `AF_INET`/`AF_INET6`, `SOCK_STREAM` only |
| 200 | bind | Implemented | IPv4/IPv6 sockaddr validated through the user-memory boundary |
| 201 | listen | Implemented | |
| 202/242 | accept/accept4 | Implemented | holds the sole physical RX capability while it works on the handshake, and gives it back before returning. Whether one call runs the whole three-way handshake depends on the rest of the machine: with nothing else runnable it waits in the kernel as it always did; with another process runnable it takes ONE step, parks the half-finished handshake on the listener, and blocks the caller (`ProcessWaitReason::NetRx`) until the next scheduler tick, which re-runs the syscall. Never `EAGAIN` for "the handshake is not finished yet" -- the caller sees a blocking accept either way. The in-kernel wait is at EL1 and kernel mode does not preempt, so a call that waited unconditionally would stop every other process for up to its whole timeout |
| 205 | getpeername | Implemented | fixed `AF_INET` reply (single-peer-per-connection model) |
| 208 | setsockopt | Partial | `optval`/`optlen` validated through the user-memory boundary when `optlen != 0`; no `level`/`optname` is actually honored, but none is meaningfully actionable in this kernel's single-listener-per-port/single-connection model either (the two real calls reached, `SO_REUSEADDR` on the listener and `SO_KEEPALIVE` on each accepted connection, are both genuinely no-ops here) |
| 210 | shutdown | Implemented | `SHUT_WR` on fd 1, both direct and inetd response modes |
| 214 | brk | Implemented | real heap-break growth within the fixed process arena |
| 215 | munmap | Unsupported-by-design | the fixed short-lived process arena is reclaimed as a unit; not reachable in practice (musl never calls `munmap` in this integration) |
| 220 | clone | Implemented | Two flag shapes: `SIGCHLD` alone (0x11), and `CLONE_VM\|CLONE_VFORK\|SIGCHLD` (0x4111), which is what musl's `vfork()` actually issues -- measured, not assumed, out of the pinned BusyBox init. Both become the same copy-on-write fork, which differs from Linux twice: the child gets its own address space rather than sharing the parent's, and the parent is not suspended until the child execs. Both differences are in the safe direction for a vfork caller, since none may rely on writes reaching the parent, but a program that read back a value the child wrote would see the pre-fork value here. Any other flag combination is `EINVAL` |
| 221 | execve | Partial | parent handoff plus child-frame replacement; resolves `argv[0]` through ext2, validates a bounded ELF metadata window, and streams PT_LOAD pages from the file. Static BusyBox applets such as `/bin/echo` are hard links to its ELF and retain argv[0]-driven multi-call dispatch; an `argv[0]` that names no ext2 file falls back to that same static image, which is what makes a bare applet name work after ash's own `PATH` search. That fallback is reached only for `argv[0]`: the PATHNAME is checked first and an absent one is refused outright, per the errno list below. `/bin/httpd` additionally maps its ext2-resident BusyBox Extras and musl interpreter pair. Copies pathname/argv, builds the child's own process-image root (whichever root it is currently scheduled on, not a fixed root), and returns child exit through the saved parent frame. A `#!` first line is dispatched to its interpreter: the directive is parsed out of a bounded first-line read at syscall time, the interpreter becomes `argv[0]`, its single optional argument follows, and the pathname `execve` was called with replaces the caller's own `argv[0]`. Every refusal is the errno Linux was measured to return: an absent pathname is `ENOENT`; a directory, a device node, or a regular file with no execute bit is `EACCES`, decided before any header byte is read; a regular file that carries neither an ELF header nor a usable `#!` line is `ENOEXEC`, which BusyBox ash turns into its own shell-script fallback; and a `#!` line naming a missing interpreter reports the interpreter's own `ENOENT` rather than a complaint about the script. The first-line window is 256 bytes, Linux's own `BINPRM_BUF_SIZE`, and is zero-filled before the read so a script with no trailing newline ends at a padding NUL exactly as it does there. `CR` is not a line terminator, so a CRLF script names an interpreter ending in `\r` and gets the same `ENOENT` Linux gives it. Nested scripts are not supported: an interpreter must itself be an executable image. |
| 260 | wait4 | Partial | blocks the caller until one of its live children exits (by specific pid or `-1`/`WAIT_ANY`), or returns 0 for `WNOHANG` while one is still live; delivers the real reaped pid and exit status, tracked per-slot so any live process -- not just the tree root -- can wait for its own child. A parent may have as many children as the page allocator allows: each exited child waits as a zombie holding its own status until collected, and `wait4(pid)` selects among them. `WUNTRACED`/`WCONTINUED`, process groups (a negative `pid`), and the `rusage` argument are not implemented |
| 261 | prlimit64 | Partial | real per-process `RLIMIT_NOFILE` (issue #393): reads the current soft/hard pair into `old_limit`, applies `new_limit`, and reports the OLD value before applying the new one. `pid` must be 0 or the caller's own (`ESRCH` otherwise) -- there is no safe cross-process path here. A resource number Linux does not have (`>= RLIM_NLIMITS` = 16) is `EINVAL`; every other resource reports `RLIM64_INFINITY` and accepts a write without storing it, which is the true answer in this kernel rather than an `EINVAL` for a resource that is genuinely unbounded. `RLIMIT_NOFILE` itself is refused above `unified_process_fd_limit_max()` (this kernel's derived `fs.nr_open`). This is the only rlimit syscall arm64 has (asm-generic defines no `getrlimit`/`setrlimit`), and musl 1.2.6's `getrlimit`/`setrlimit` both go through it, so it is what ash's `ulimit -n` reaches. Exercised end-to-end by the EL0 payload: read 1024/4096, lower the soft limit to 64, read it back, restore |
| 222 | mmap | Partial | anonymous-only (`MAP_PRIVATE\|MAP_ANONYMOUS`, `fd=-1`, no `PROT_EXEC`) via a heap-break-cursor emulation, not a real independent mapping; every real call shape musl's mallocng makes satisfies this (verified against the pinned musl 1.2.6 source directly) |
| 226 | mprotect | Partial | real permission changes for exactly one transition (`RW+XN` <-> `R+XN` on data/heap/stack); anything else (adding `PROT_EXEC`, targeting text/rodata, mixed-class ranges) returns a real `EACCES`/`EINVAL`, never false success |
| 451 | (Takibi-internal) UART RX wait | Implemented | not a real Linux syscall number; this kernel's own blocking-UART-RX primitive |
| 452 | (Takibi-internal) parent progress | Implemented | not a real Linux syscall number; concurrency-proof instrumentation only |
| 453 | (Takibi-internal) workload progress | Implemented | not a real Linux syscall number. One round of CPU-bound work finished, reported by the `/bin/busy-a`/`/bin/busy-b` pair `/etc/inittab` starts. `x0` names which entry is speaking, `x1` carries that entry's xorshift correctness checksum, and `x2` records the input steps per round. The answer is an instruction: `0` keep working and keep reporting, `1` keep working and stop reporting, `2` exit now so `init` has to respawn it. Refused for a caller that is not a child of `init`, so an unrelated process cannot satisfy the assertion on the pair's behalf. |

## Syscalls confirmed correctly Unsupported-by-design

These were named in the false-success audit's original problem list (written
against the older `examples/el0_shell` fixture) but are simply not implemented in
`kernel/`, so they already return `LINUX_ENOSYS` -- confirmed intentional,
not an oversight:

| # | name |
|---|------|
| 25 | fcntl |
| 68 | pwrite64 |
| 167 | prctl |
| 278 | getrandom |
| 293 | rseq |

## Maintenance note

When a new syscall arm is added, add its row here in the same commit, and
classify it Implemented/Partial/Unsupported-by-design. Do not copy a
false-success shortcut from `examples/el0_shell` into this file's
Implemented/Partial rows without a real reason documented alongside it.

**When a Partial row's behavior changes, change the row in the same commit.**
A `Partial` note describes what the kernel does right now, not what it did
when the row was written; a stale row here is worse than no row, because it
is read as the contract.

Describe behavior rather than citing issue numbers. A row saying a gap is
"tracked in #N" goes stale the moment #N closes -- which is exactly how the
`ppoll` row survived for a day claiming the call never blocks after blocking
had been implemented. Planned work belongs on the
[project board](https://github.com/orgs/takibi-lang/projects/2).
