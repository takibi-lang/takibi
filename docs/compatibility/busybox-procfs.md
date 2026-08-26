# BusyBox procfs compatibility contract

This document records the procfs behavior required by the BusyBox binary
shipped in the kernel root filesystem. It is an implementation input for the
kernel's read-only procfs, not a commitment to implement all of Linux procfs.

## Audited artifact

- Alpine package: `busybox-static-1.37.0-r31.apk`
- Alpine repository: v3.24, aarch64
- BusyBox upstream version: 1.37.0
- Alpine aports commit recorded by the package:
  `c3ef5d10e6ef6528852c51f0564963e2f8c1be19`
- Binary installed in the root filesystem: `/bin/busybox.static`

The Alpine configuration enables `CONFIG_DESKTOP`, `CONFIG_PS`,
`CONFIG_FEATURE_PS_TIME`, `CONFIG_FEATURE_PS_ADDITIONAL_COLUMNS`, and
`CONFIG_FEATURE_SHOW_THREADS`. It disables SELinux and the `PS_WIDE`,
`PS_LONG`, and `PS_UNUSUAL_SYSTEMS` features. The Alpine patches for this
package do not modify `procps/ps.c` or `libbb/procps.c`.

The separately installed `busybox-extras-1.37.0-r31.apk` does not enable the
`ps` applet and therefore does not define this contract.

## Minimum contract for default `ps`

The default command prints `pid,user,time,args`. To produce one process row,
BusyBox performs the following operations:

1. Enumerate numeric entries in `/proc`.
2. `stat` `/proc/<pid>/` and use the directory's effective UID and GID.
3. Read `/proc/<pid>/stat` for the command name, user CPU time, and system CPU
   time.
4. Read `/proc/<pid>/cmdline` for the displayed command and arguments.
5. Call `sysinfo` once to obtain uptime. The default output does not read
   `/proc/uptime` on this Linux build.

The process directory must therefore support directory enumeration and stat;
providing only readable virtual files is insufficient. A process which exits
between enumeration and a later operation is skipped, which gives the desired
best-effort race behavior without requiring a global snapshot.

`/proc/<pid>/cmdline` is a sequence of NUL-separated argument strings. BusyBox
turns control characters, including separators, into spaces. If the file is
empty or unreadable, it falls back to the command name from `stat`, displayed
in brackets. The file may therefore be omitted from an initial implementation
without making `ps` fail, but doing so loses command-line diagnostics.

## `/proc/<pid>/stat` fields

BusyBox reads at most 1023 bytes and locates the last `)` before parsing the
remaining whitespace-separated fields. The record must preserve Linux field
positions through field 39 even when a selected output column needs only a
subset. Alpine enables `CONFIG_FEATURE_TOP_SMP_PROCESS`, so BusyBox scans the
additional fields even when `ps` does not display its CPU column:

| Field | Linux name | BusyBox use |
| ---: | --- | --- |
| 1 | pid | Process identity and record prefix |
| 2 | comm | `comm`, `args` fallback |
| 3 | state | `stat` |
| 4 | ppid | `ppid` |
| 5 | pgrp | `pgid` |
| 6 | session | `sid` |
| 7 | tty_nr | `tty` |
| 8-13 | tpgid through cmajflt | Parsed and discarded |
| 14 | utime | `time` |
| 15 | stime | `time` |
| 16-18 | cutime through priority | Parsed and discarded |
| 19 | nice | `nice` and state suffix |
| 20-21 | num_threads and itrealvalue | Parsed and discarded |
| 22 | starttime | `etime` |
| 23 | vsize | `vsz`, converted from bytes to KiB |
| 24 | rss | `rss`, converted from pages to KiB |
| 25-38 | rsslim through exit_signal | Parsed and discarded |
| 39 | processor | Last CPU value retained by the shared procps scanner |

At least 11 selected conversions in BusyBox's parser must succeed; a malformed
or shortened record causes that process to be skipped. Keeping Linux's field
positions is therefore materially more important than populating every field
with meaningful data. Unsupported numeric fields can initially be zero where
that does not misrepresent a kernel invariant.

## Optional columns and threads

The pinned binary accepts these `-o` columns:

| Columns | Additional requirement |
| --- | --- |
| `pid` | Numeric `/proc` directory entry only |
| `user`, `group` | Ownership returned by `stat("/proc/<pid>/")` |
| `comm`, `ppid`, `pgid`, `etime`, `nice`, `time`, `tty`, `vsz`, `sid`, `stat`, `rss` | Corresponding fields in `/proc/<pid>/stat` |
| `args` | `/proc/<pid>/cmdline`, with `stat` command-name fallback |
| `ruser`, `rgroup` | First numeric values on `Uid:` and `Gid:` lines in `/proc/<pid>/status` |

Because thread display is enabled, `ps -T` additionally enumerates
`/proc/<pid>/task/<tid>/` and reads its `stat` and `cmdline` entries. Thread
display is not required for the default command and should not expand the
first procfs milestone unless there is a concrete user-space need for it.

Neither `/proc/<pid>/fd/` nor `/proc/net/tcp` is accessed by the `ps` applet.
Those paths serve separate diagnostics and must be specified from their actual
consumers rather than inferred from `ps`.

## libc and syscall boundary

The static BusyBox binary contains its musl implementation, but the following
kernel-visible behavior is still part of the command's dependency surface:

- `openat`, `getdents64`, `newfstatat`, `read`, and `close` for procfs;
- `sysinfo` for elapsed-time formatting;
- page-size discovery for converting RSS pages to KiB;
- `isatty`/`ioctl(TIOCGWINSZ)` only when standard output is a terminal.

User and group name lookup may read `/etc/passwd` and `/etc/group`. BusyBox
falls back to the decimal UID or GID when no name is found, so these files are
not procfs prerequisites. They affect display quality, not process discovery.

## Evidence and audit boundary

The contract was derived from the exact Alpine configuration and the BusyBox
1.37.0 `procps/ps.c` and `libbb/procps.c` sources. It was checked by executing
the pinned aarch64 static binary under user-mode emulation and tracing both
default `ps` and a command selecting every supported `-o` column. The trace
confirmed `/proc` enumeration, process-directory stat, reads of `stat`,
`cmdline`, and (for real-ID columns) `status`, plus the optional account-file
lookups and `sysinfo` call.

A runtime trace demonstrates the exercised paths but cannot establish that an
unexercised option has no dependency. Source and build-configuration analysis
therefore define the contract; tracing is corroborating evidence.

Re-audit this document whenever the BusyBox package URL or version in the root
`Makefile` changes, or when a newly supported BusyBox command is intended to
consume procfs. A musl-only version change does not by itself require redoing
the procfs format analysis, but it does require checking that the syscall ABI
assumptions above remain valid.
