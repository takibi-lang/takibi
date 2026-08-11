# Syscall support matrix

Every syscall number `kernel_syscall_dispatch` (`kernel/kernel/syscall.tkb`)
recognizes, what it actually does, and why. Anything not listed here falls
through to the final `return (1, LINUX_ENOSYS);` and is Unsupported by
design. This file exists so that state is documented rather than silently
true.

Reached-by-BusyBox column reflects the real, traced integration this kernel
runs: pinned Alpine `busybox-static`/`busybox-extras` 1.37.0-r31 (ash +
`httpd -f -p 8080 -h /`) dynamically linked against pinned `musl` 1.2.6-r2
(see `Makefile`'s `KERNEL_BUSYBOX_URL`/`KERNEL_HTTPD_URL`/`KERNEL_MUSL_URL`).

| # | name | status | notes |
|---|------|--------|-------|
| 17 | getcwd | Implemented | this kernel has exactly one real directory (`/`); always returns it. Returns the real byte count written (matching the raw syscall's own contract, distinct from the POSIX library wrapper's buffer-pointer return) -- previously returned the buffer address instead, never caught because no scenario called it before the `sh -c` scenario did |
| 24 | dup3 | Implemented | accepted-fd -> stdin/stdout aliasing only, matching the traced daemon child's own shape |
| 49 | chdir | Implemented | succeeds only for `/` (`ENOENT` otherwise) -- honest, since the one real cwd never actually changes |
| 56 | openat | Implemented | generic NUL-terminated absolute pathname lookup, including the rootfs's bounded nested directories, against the ext2 mount; `dirfd` ignored |
| 57 | close | Implemented | |
| 61 | getdents64 | Unsupported-by-design | directory FD state and ext2 directory enumeration are not implemented; the syscall falls through to `ENOSYS`, so BusyBox `ls` is not yet supported |
| 63 | read | Implemented | connected-socket, ext2-file, and UART-fallback paths, all through the typed user-memory boundary (`kernel/mm/user_memory.tkb`); an empty UART RX path blocks and wakes on received input, as exercised by the foreground interactive ash REPL |
| 64 | write | Implemented | same three paths as `read`, plus the inetd-response path |
| 65 | readv | Partial | fd 3 (ext2 file) only, via a standalone segment helper not shared with `read`(64)'s TCP/inetd branches. Each iovec entry validated and copied individually through the user-memory boundary (`struct packed Iovec`, `IOV_MAX`-bounded, `checked_mul_usize`/`checked_add_usize`-guarded array-length and running-total arithmetic). Connected-TCP and inetd-mode fds are not supported |
| 66 | writev | Partial | fd 1/2 (UART) only -- same scoping and same fd-kind gap as `readv` above |
| 71 | sendfile | Implemented | fd 3 (ext2 file) -> fd 1/2 (UART) only, offset must be 0 |
| 73 | ppoll | Partial | real pollfd array validation (`struct packed Pollfd`, `POLL_MAX`-bounded) and real per-fd readiness (UART RX pending, connected-TCP buffered data). Really blocks and wakes on UART RX for exactly one shape: `nfds == 1`, fd 0, `POLLIN` requested, nothing ready, NULL timeout and NULL sigmask -- the shape BusyBox ash's `read` builtin uses. Every other shape returns current readiness immediately, so a non-NULL timeout is never armed and no multi-fd wait exists |
| 79 | newfstatat | Implemented | generic ext2 pathname lookup plus fixed asm-generic AArch64 `stat` fields for regular files, directories, and symlinks |
| 93/94 | exit/exit_group | Implemented | real child-vs-parent teardown via the process/fd/VM-clone machinery |
| 96 | set_tid_address | Implemented | returns the real current pid (single-threaded-per-process model) |
| 103 | setitimer | Partial | previous timer is honestly zeroed; no real itimer is armed (this kernel's bounded single-request integration scope never needs `SIGALRM` to actually fire) |
| 113 | clock_gettime | Implemented | fixed epoch-ish timestamp; sufficient for BusyBox httpd's own use |
| 134 | rt_sigaction | Partial | `signum` validated (`EINVAL` for 0/`SIGKILL`/`SIGSTOP`); non-null `oldact` is validated and zero-filled via the user-memory boundary instead of left uninitialized; no real signal delivery exists, so an installed handler is never actually invoked (the false-success audit recorded why this is safe against the real traced calls: `signal(SIGPIPE\|SIGALRM\|SIGCHLD\|SIGHUP, ...)`, none of which check the return value) |
| 135 | rt_sigprocmask | Implemented | previous mask is honestly zeroed |
| 160 | uname | Implemented | real `struct utsname` reply via the user-memory boundary (`sysname="Linux"`, `nodename="takibi"`, `release="6.1.0-takibi"`, `version="#1"`, `machine="aarch64"`), zero-filled scratch buffer first so no uninitialized kernel memory reaches userspace |
| 172 | getpid | Implemented | |
| 173 | getppid | Implemented | always returns 0; a real parent link exists (`scheduled_process_parent`) but nothing traced needs a real ppid, so it is not wired up |
| 174-177 | getuid/geteuid/getgid/getegid | Implemented | return 0 (always-root model) |
| 178 | gettid | Implemented | returns the real current pid |
| 198 | socket | Implemented | `AF_INET`/`AF_INET6`, `SOCK_STREAM` only |
| 200 | bind | Implemented | IPv4/IPv6 sockaddr validated through the user-memory boundary |
| 201 | listen | Implemented | |
| 202/242 | accept/accept4 | Implemented | holds the sole physical RX capability across the blocking handshake |
| 205 | getpeername | Implemented | fixed `AF_INET` reply (single-peer-per-connection model) |
| 208 | setsockopt | Partial | `optval`/`optlen` validated through the user-memory boundary when `optlen != 0`; no `level`/`optname` is actually honored, but none is meaningfully actionable in this kernel's single-listener-per-port/single-connection model either (the two real calls reached, `SO_REUSEADDR` on the listener and `SO_KEEPALIVE` on each accepted connection, are both genuinely no-ops here) |
| 210 | shutdown | Implemented | `SHUT_WR` on fd 1, both direct and inetd response modes |
| 214 | brk | Implemented | real heap-break growth within the fixed process arena |
| 215 | munmap | Unsupported-by-design | the fixed short-lived process arena is reclaimed as a unit; not reachable in practice (musl never calls `munmap` in this integration) |
| 220 | clone | Implemented | `CLONE_VM\|CLONE_VFORK` shape only, matching BusyBox httpd's own observed fork usage |
| 221 | execve | Partial | parent handoff plus child-frame replacement; resolves `argv[0]` through ext2, validates a bounded ELF metadata window, and streams PT_LOAD pages from the file. Names without a separate ELF fall back to the ext2-resident static BusyBox, preserving its argv[0]-driven multi-call dispatch for `/echo`/`/bin/echo`; `/busybox-httpd` additionally maps its ext2-resident BusyBox Extras and musl interpreter pair. Copies pathname/argv, builds the child's own process-image root (whichever root it is currently scheduled on, not a fixed root), and returns child exit through the saved parent frame |
| 260 | wait4 | Partial | blocks the caller until its live child exits (by specific pid or `-1`/`WAIT_ANY`), or returns 0 for `WNOHANG` while it is still live; delivers the real reaped pid and exit status, tracked per-slot so any live process -- not just the tree root -- can wait for its own child; a process may have at most one live child at a time, so concurrent multi-child wait/reap remains out of scope |
| 222 | mmap | Partial | anonymous-only (`MAP_PRIVATE\|MAP_ANONYMOUS`, `fd=-1`, no `PROT_EXEC`) via a heap-break-cursor emulation, not a real independent mapping; every real call shape musl's mallocng makes satisfies this (verified against the pinned musl 1.2.6 source directly) |
| 226 | mprotect | Partial | real permission changes for exactly one transition (`RW+XN` <-> `R+XN` on data/heap/stack); anything else (adding `PROT_EXEC`, targeting text/rodata, mixed-class ranges) returns a real `EACCES`/`EINVAL`, never false success |
| 451 | (Takibi-internal) UART RX wait | Implemented | not a real Linux syscall number; this kernel's own blocking-UART-RX primitive |
| 452 | (Takibi-internal) parent progress | Implemented | not a real Linux syscall number; concurrency-proof instrumentation only |

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
