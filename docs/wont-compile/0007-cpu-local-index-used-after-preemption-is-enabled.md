# 0007. A CPU-local index used after preemption is enabled again

| Field | Value |
| --- | --- |
| Status | Enforced |
| Compared against | Linux smp_processor_id, Rust for Linux (2026-10-16) |
| Check | type error, CPU authority rules (`lib/type_inf.ml`) |
| Test case | `the authority cannot escape a block by return, even in the mint file` |
| Introduced | 2026-10-16, GitHub issue #638 |
| Specified in | [`SPEC.md`](../../SPEC.md) "Per-CPU Storage" and "Preemption-disabled regions" |

![A CPU index carried out of its region, then used on another
CPU](assets/0007-cpu-local-index-used-after-preemption-is-enabled.svg)

## The defect

Code reads which CPU it is on and uses that number to pick its per-CPU slot.
If the number outlives the stretch in which preemption is disabled, the task
can be moved to another CPU in between, and it then writes into the slot of
a CPU it no longer runs on, while that CPU's own task writes there too.

## What C and Rust do about it

**C: a runtime warning.** Linux's `smp_processor_id()` warns under
`CONFIG_DEBUG_PREEMPT` when called with preemption enabled; the value it
returns is an `int` and can be kept as long as the caller likes.

**Rust: not in the language.** Rust for Linux exposes the CPU number as an
integer; tying it to a preemption guard is a library convention.

Sources: [Linux this_cpu operations](https://www.kernel.org/doc/html/latest/core-api/this_cpu_ops.html).

## What Takibi does

The CPU index is a `cpu_authority` value, never an integer, and the only way
to get one outside its file is a `preempt_off` block. It cannot be stored in
a global, a field or a place, and it cannot be returned out of the block, so
it lives exactly as long as the region.

## Code that does not compile

```takibi
struct cpu_authority CpuHere { private id: {0..<4 as usize}; }

private fn preempt_off_enter() -> CpuHere {
    let mut cpu: CpuHere = { 0 };
    return cpu;
}

struct per_cpu Scratch { bytes: [u8; 64]; }
private let mut scratch: [Scratch; 4];

fn this_cpu() -> CpuHere {
    preempt_off (cpu) { return cpu; }
}

fn fill() {
    let mut cpu: CpuHere = this_cpu();
    scratch[cpu].bytes[0] = 1;
}
```

```text
function 'this_cpu' cannot return the CPU authority: it is valid only
  inside the preempt_off block that minted it
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

fn fill() {
    preempt_off (cpu) {
        scratch[cpu].bytes[0] = 1;
    }
}
```

## Where this runs

Every per-CPU store in the kernel (`struct per_cpu`) is indexed only by this
authority.

## Limits of this entry

The authority file is trusted, and it may publish mints that bypass a block;
`scripts/check_cpu_authority_mints.py` fixes their callers. Many per-CPU
arrays are still indexed by the raw `cpu_id()` integer; they move to
`struct per_cpu` file by file (#638).
