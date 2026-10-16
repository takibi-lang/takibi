# 0006. A blocking call while preemption is disabled

| Field | Value |
| --- | --- |
| Status | Enforced |
| Compared against | Linux might_sleep, Rust for Linux klint (2026-10-16) |
| Check | type error, effect checker on `preempt_off` blocks (`lib/type_inf.ml`) |
| Test case | `blocking reached through a callee given the authority` |
| Introduced | 2026-10-16, GitHub issue #638 |
| Specified in | [`SPEC.md`](../../SPEC.md) "Preemption-disabled regions" |

![A preempt_off region whose call path reaches a blocking function, rejected
at compile time](assets/0006-blocking-call-while-preemption-is-disabled.svg)

## The defect

A kernel disables preemption so that a stretch of code stays on one CPU:
per-CPU scratch, a per-CPU counter, a lock that the same CPU must not
re-enter. If that stretch then sleeps, one of two things goes wrong. Either
the sleep switches away anyway, and the next task on the same CPU finds the
scratch half written, or the CPU waits with preemption off for a wakeup
that needs the scheduler, and stalls.

As with a blocking call in an interrupt handler (0001), the call that sleeps
is rarely in the region itself. The region calls a helper that reads a
block, and the block read takes a sleeping lock. Each function is correct
alone; the defect is the composition.

## What C and Rust do about it

**C: Linux's runtime check.** `might_sleep()` compares the preemption count
and prints `BUG: sleeping function called from invalid context`, when
`CONFIG_DEBUG_ATOMIC_SLEEP` is set and the path runs. A rare branch can stay
silent for years.

**Rust: an external lint.** Rust's types say nothing about atomic context.
Rust for Linux's `klint` tracks the preemption count at compile time through
its own annotations and analysis, outside the language and only where it is
run.

Sources: [Linux might_sleep](https://github.com/torvalds/linux/blob/master/include/linux/kernel.h)
and [klint atomic context](https://github.com/Rust-for-Linux/klint/blob/master/doc/atomic_context.md).

## What Takibi does

`preempt_off (cpu) { ... }` is the region, and the only way to obtain the
CPU authority that indexes a per-CPU store. The compiler summarizes the
region's calls as it summarizes a function body and rejects the region when
`may_block` is reachable, naming the path. An indirect call with no effect
row is rejected rather than assumed harmless, as under an interrupt root.

## Code that does not compile

```takibi
struct cpu_authority CpuHere { private id: {0..<4 as usize}; }

private fn preempt_off_enter() -> CpuHere {
    let mut cpu: CpuHere = { 0 };
    return cpu;
}

struct per_cpu Scratch { bytes: [u8; 64]; }
private let mut scratch: [Scratch; 4];

extern fn disk_wait() !{may_block};

fn disk_read_into(cpu: CpuHere) {
    disk_wait();
    scratch[cpu].bytes[0] = 1;
}

fn parse_block() {
    preempt_off (cpu) {
        disk_read_into(cpu);
    }
}
```

```text
preempt_off block in function 'parse_block' may block via
  disk_read_into -> disk_wait; preemption stays disabled for the whole
  block, so nothing in it may block
```

## Code that does compile

```takibi
struct cpu_authority CpuHere { private id: {0..<4 as usize}; }

private fn preempt_off_enter() -> CpuHere {
    let mut cpu: CpuHere = { 0 };
    return cpu;
}

struct per_cpu Scratch { bytes: [u8; 64]; }
private let mut scratch: [Scratch; 4];

extern fn disk_wait() !{may_block};

fn parse_block() {
    disk_wait();
    preempt_off (cpu) {
        scratch[cpu].bytes[0] = 1;
    }
}
```

The wait happens before the region; the region only touches the CPU's own
scratch.

## Where this runs

`kernel/kernel/syscall.tkb` reaches the exec-argument handoff through
`preempt_off` blocks. ext2's per-CPU scratch is held across block I/O, which
may block, so the region rule rejects it; it takes its authority from
`cpu_here_across_blocking()` until that scratch moves to per-task storage
(#638).

## Limits of this entry

While `KERNEL_PREEMPTIBLE` is 0 the region lowers to no disable or enable
instruction; the mint file asserts the constant. The region is lexical; a
region that ends elsewhere, such as at a lock release, waits for the linear
token form (#638, #789).
