# 0002. A handle that may name a destroyed object

| Field | Value |
| --- | --- |
| Status | Enforced |
| Check | type error, handle invalidation (`lib/type_inf.ml`) |
| Test case | `issue #493: a handle is dead after a call that may destroy its object` |
| Introduced | 2026-09-13, commit `297b299f` ("kill a plain handle at a call that may destroy its object") |
| Specified in | [`OWNERSHIP_KERNEL.md`](../../OWNERSHIP_KERNEL.md) |

![A handle naming slot 7 survives a call that frees slot 7 and hands it to a
new task](assets/0002-handle-that-may-name-a-destroyed-object.svg)

## The defect

A kernel refers to its objects by handle: a slot index, usually with a
generation counter beside it. A handle is plain data. It can be copied,
stored, passed, and returned, and none of that touches the object it names.

So the object can die while the handle is still in a register. A process
reaps a child, an allocator returns a page to its pool, a descriptor ring
recycles an entry -- and the slot is immediately handed to something else.
The holder then reads through a handle that is perfectly well-formed and
points at a different object than it did one call ago.

What makes this hard is the distance and the direction. The call that
destroys the object does not take the handle as an argument. In the figure,
`deliver_signal()` does not take `child` at all; the reap is two frames
further down. Nothing in the caller's text connects the two, and that is
exactly why reading the caller does not reveal the defect.

## What C and Rust do about it

**C: nothing.** A handle is an integer, and the language has no opinion about
what it names. A pid is this same handle with the generation left out, which
is why the reuse race is the instance every Linux user has met: between
looking up a pid and acting on it, the process can exit and the number can be
handed to a new one, so the signal lands on a stranger. Linux's fix was not a
language change but a new kind of handle -- `pidfd`, a file descriptor that
pins the identity it names.

A generation is the cheaper repair, and the one this entry's handle already
carries. It makes the reuse *detectable*, by comparing the generation on each
lookup -- which is a check, at run time, that somebody has to remember to
write. Inside the kernel the general answer is a reference count plus
convention about who holds one, and the paths that forget are the recurring
use-after-free shape.

**Rust: not this.** The borrow checker reasons about *references* and their
lifetimes. A handle is not a reference: it is a `u32` pair with no lifetime,
so nothing in the type system relates it to the slot's contents.

Crates fill the gap and do it well: `slotmap` and `generational-arena` store a
generation beside the slot and compare it on every lookup. Two things are
still true. That comparison is a **runtime** one, paid on each access and
answered with a `None` the caller must handle. And it is a property of the
crate rather than of the language, so reaching for one without generations --
`slab` hands out bare indices -- leaves the defect exactly as it was. What no
crate can do is lift the check into the type, because the language has nowhere
to put it.

Both languages end up detecting this while the kernel runs, if at all. The
difference is not that Takibi is safer at run time; it is that the question
is answered before the binary exists.

## What Takibi does

Two markers, and the checker joins them.

A function that can destroy the object behind a `TaskHandle` declares
`!{invalidates_TaskHandle}` -- an effect named after the struct, so the
relation is between a specific handle type and the functions that can kill
its objects. The effect propagates through direct calls exactly like the
operational effects, which is how a marker two frames down reaches a caller
that never mentions it.

A binding of that struct type is then dead from the first call that reaches
such a function. The diagnostic names the call, the path to the marked
function, and both repairs.

The escape is a **witness**: an accessor marked `!{handle_of_witness}` derives
a handle from a borrowed linear value, and the handle stays live for as long
as that witness does. The handle is still plain data; what changed is that
holding it is now underwritten by something the checker can track. This is
what the accepted program below does.

Branch and loop joins are handled the way consumption already was: destroyed
on one path means dead after the join. The second rejected program below is a
call under `if`, and the handle does not survive it.

## Code that does not compile

```takibi
linear view TaskZombie[id: usize];

struct TaskHandle { slot: usize; generation: usize; }

fn task_reap(z: sink TaskZombie[id]) !{invalidates_TaskHandle} {}
fn task_slot(h: TaskHandle) -> usize { return h.slot; }

fn wait_and_reap() {
    let z = view TaskZombie[3];
    task_reap(z);
}

fn deliver_signal() { wait_and_reap(); }

fn signal_then_use(child: TaskHandle) -> usize {
    deliver_signal();
    return task_slot(child);
}
```

```text
'child' (TaskHandle) may name a destroyed object: 'deliver_signal' at line 16
(deliver_signal -> wait_and_reap -> task_reap) reaches a function marked
invalidates_TaskHandle, and no live witness vouches for this handle.
Re-derive it after that call, or take it from a handle_of_witness accessor
and keep the witness live across the call
```

Destroying the object on only one path is enough. After the join the handle
is dead on every path, because the checker cannot tell which one ran:

```takibi
linear view TaskZombie[id: usize];

struct TaskHandle { slot: usize; generation: usize; }

fn task_reap(z: sink TaskZombie[id]) !{invalidates_TaskHandle} {}
fn task_slot(h: TaskHandle) -> usize { return h.slot; }

fn wait_and_reap() {
    let z = view TaskZombie[3];
    task_reap(z);
}

fn deliver_signal() { wait_and_reap(); }

fn maybe_signal(child: TaskHandle, deliver: bool) -> usize {
    if (deliver) { deliver_signal(); }
    return task_slot(child);
}
```

```text
'child' (TaskHandle) may name a destroyed object: 'deliver_signal' at line 16
(deliver_signal -> wait_and_reap -> task_reap) reaches a function marked
invalidates_TaskHandle, and no live witness vouches for this handle.
Re-derive it after that call, or take it from a handle_of_witness accessor
and keep the witness live across the call
```

## Code that does compile

The handle comes from an accessor that ties it to a borrowed linear witness,
and the witness is still live across the call:

```takibi
linear view TaskAlive[id: usize];
linear view TaskZombie[id: usize];

struct TaskHandle { slot: usize; generation: usize; }

fn task_reap(z: sink TaskZombie[id]) !{invalidates_TaskHandle} {}
fn task_slot(h: TaskHandle) -> usize { return h.slot; }

fn task_take() -> TaskAlive[1] { return view TaskAlive[1]; }
fn task_exit(c: sink TaskAlive[id]) {}

fn task_current(c: borrow TaskAlive[id]) -> TaskHandle !{handle_of_witness} {
    let mut h: TaskHandle = { 0, 0 };
    return h;
}

fn wait_and_reap() {
    let z = view TaskZombie[3];
    task_reap(z);
}

fn deliver_signal() { wait_and_reap(); }

fn signal_then_use() -> usize {
    let c = task_take();
    let mut child: TaskHandle = task_current(c);
    deliver_signal();
    let slot: usize = task_slot(child);
    task_exit(c);
    return slot;
}
```

Re-deriving the handle after the destroying call is the other repair, and it
needs no witness: a fresh value has no history to be dead from.

## Limits of this entry

The relation is declared, not inferred: a function that can destroy a task
and does not say `!{invalidates_TaskHandle}` buys nothing here, which is why
the marker belongs on the small reviewed set of functions that actually reap.
The analysis is function-local, so a handle stored into a global and read
back elsewhere leaves what this check can see;
[`OWNERSHIP_KERNEL.md`](../../OWNERSHIP_KERNEL.md) records where that boundary
currently sits.
