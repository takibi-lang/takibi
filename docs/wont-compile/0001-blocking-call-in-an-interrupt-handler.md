# 0001. A blocking call inside an interrupt handler

| Field | Value |
| --- | --- |
| Status | Enforced |
| Check | type error, effect checker (`lib/type_inf.ml`) |
| Test case | `Slice 4: interrupt root rejects a transitive blocking call` |
| Introduced | 2026-07-16, commit `2c7a436b` ("Slice 4: runtime mutable owners and effects") |
| Specified in | [`SPEC.md`](../../SPEC.md) effect contracts, [`EFFECTS.md`](../../EFFECTS.md) |

![A call path from an interrupt handler to a blocking function, rejected at
compile time](assets/0001-blocking-call-in-an-interrupt-handler.svg)

## The defect

An interrupt handler runs in a context that cannot wait. On entry the hardware
has masked further interrupts on that core, and nothing will preempt the
handler to run someone else. A function it calls that sleeps, spins for a
device, takes a sleeping lock, or allocates from a pool that may sleep,
therefore waits for an event that can no longer arrive: the wakeup would come
from an interrupt, and interrupts are masked because the handler is running.
The core stops there.

What makes this a catalog entry rather than a coding tip is the distance
involved. The handler rarely calls the blocking function directly. It calls a
helper, which calls a logging routine, which calls the UART write, which spins
on a ready bit. Every function on that path except the two ends is ordinary
code that is perfectly correct in every other caller, and none of them is
wrong on its own. The defect exists only in the composition, which is exactly
what reading a single function cannot show you.

## What C and Rust do about it

**C: nothing at compile time.** Linux detects this at run time, with
`might_sleep()` annotations that expand to a check of the preemption count and
print `BUG: sleeping function called from invalid context`. That is a good
mechanism and it has three limits: it requires `CONFIG_DEBUG_ATOMIC_SLEEP`,
which production kernels do not ship; it fires only if the path actually
executes, so a rare error branch in a handler can stay undetected for years;
and it is a convention maintained by hand, so a function that starts sleeping
after a refactor does not automatically gain the annotation its callers relied
on.

**Rust: nothing in the language.** Rust's type system has no effect system,
and `Send`/`Sync` model which thread may touch a value, not which context may
run a function. A `&mut` reference says nothing about whether the callee
sleeps. Rust for Linux carries the same problem as C here, and the evidence
that it is a real problem rather than a theoretical one is that the project
built an out-of-tree MIR linter, `klint`, specifically to track preemption
count and reject sleeping calls in atomic context. That tool confirms the
hazard is worth checking; it is also a separate analysis bolted onto a
language that cannot express the property, so what it checks is not part of
any function's published type.

Takibi's claim here is narrow and worth stating precisely: the property is in
the function type, the compiler that produces the kernel binary enforces it,
and no configuration option turns it off.

## What Takibi does

`!{interrupt}` is a declaration role, not an inferred effect. It marks a
handler root. The checker then walks the complete reachable call graph from
that root and rejects it if `may_block`, `allocates`, or `logs` is reachable.

Those three are inferred, not declared. `uart_put` in the figure declares no
effect at all and is still part of the reported path, because the effect comes
up from the leaf through resolved direct calls. An explicit annotation is an
API contract and a seed for inference, not a tax on every intermediate caller.

The diagnostic names one offending path end to end, which is what makes the
error actionable: the defect is the composition, so a message that named only
the leaf would send you to a function that is not wrong.

Two further rules close the ways a call graph can go dark:

- An indirect call through a function pointer with no effect row is rejected
  under an interrupt root. An unknown callee is not assumed harmless.
- A function pointer whose row declares `may_block` is rejected there too, so
  a callback slot cannot launder the effect.

`locks` is deliberately excluded from the forbidden set (GitHub issue #449).
It propagates like the others and a bare `!{}` contract still forbids it, but a
lock whose acquire masks interrupts composes correctly with a handler -- the
handler cannot interrupt a holder on the same core. That is a property of the
lock, and a lock that does not mask says so by carrying `may_block`, which is
forbidden. The exclusion is a judgment about what the effect means, not a hole.

`logs` is forbidden for a reason worth repeating in a talk: at 115200 baud a
forty-character line takes 3.5 ms, and the scheduler tick is 15.6 ms.

## Code that does not compile

```takibi
extern fn uart_wait_ready() !{may_block};

fn uart_put(c: u8) {
    uart_wait_ready();
}

fn timer_irq_handler() !{interrupt} {
    uart_put(46);
}
```

```text
interrupt function 'timer_irq_handler' may block via
  timer_irq_handler -> uart_put -> uart_wait_ready
```

An unknown indirect callee is rejected on the same grounds:

```takibi
fn timer_irq_handler(callback: fn() -> void) !{interrupt} {
    callback();
}
```

```text
interrupt function 'timer_irq_handler' reaches a call with unknown effects via
  timer_irq_handler -> <indirect call>
```

And so is a callback whose contract admits blocking:

```takibi
fn timer_irq_handler(callback: fn !{may_block}() -> void) !{interrupt} {
    callback();
}
```

```text
interrupt function 'timer_irq_handler' may block via
  timer_irq_handler -> <indirect call !{may_block}>
```

## Code that does compile

```takibi
extern fn ack_irq();

fn handler_helper() { ack_irq(); }

fn timer_irq_handler() !{interrupt} { handler_helper(); }
```

The accepted form is not a weaker version of the rejected one. Nothing was
annotated to make it pass: the call graph simply does not reach a blocking
leaf, and the checker can see that.

## Where this runs

`!{interrupt}` roots in the maintained kernel include
`kernel/arch/arm64/kernel/timer.tkb` (`timer_irq_handler`) and
`kernel/drivers/net/rp1_gem.tkb` (`gem_irq_handler`). The whole kernel is built
under `--forbid-trap`, so these are not demonstration programs.

## Limits of this entry

The check covers what the compiler can resolve. Reachability through an
indirect call is handled by rejecting the unknown case rather than by proving
the target, which is conservative in the safe direction but means a handler
that genuinely needs a dynamic dispatch must carry an effect-contracted
function-pointer row to say so. Hand-written assembly reached from a handler is
outside the language model; [`TRUSTED_BASE.md`](../../TRUSTED_BASE.md) states
that boundary. This entry describes the interrupt root; `exception` and
`mmu_off` are separate roles with their own forbidden sets, recorded in
[`EFFECTS.md`](../../EFFECTS.md).
