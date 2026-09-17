# 0004. An unproven index that leaves a trap in the kernel

| Field | Value |
| --- | --- |
| Status | Enforced |
| Check | `--forbid-trap`, over the codegen trap-site accounting (`lib/llvm_gen.ml`) |
| Test case | `every runtime-trap lowering records one site and emits one llvm.trap call` |
| Introduced | 2026-07-04, commit `feea9a74` ("Introduce --forbid-trap option") |
| Compile with | `--forbid-trap` |
| Specified in | [`TRUSTED_BASE.md`](../../TRUSTED_BASE.md) |

![One array access, three outcomes: no check in C, a check that panics in
Rust, and a build that stops in Takibi](assets/0004-unproven-index-leaves-a-trap.svg)

## The defect

An array index arrives from somewhere the code does not control -- a packet
field, an MMIO read, a syscall argument, an interrupt status word -- and is
used to address a table. The question "is this index inside the table" has
exactly three answers available in a shipped kernel binary, and two of them
are bad.

Nobody asks: the write lands outside the table and the kernel continues with
some other structure quietly modified. This is the memory corruption that
makes kernel bugs security bugs, and it is the C answer.

Somebody asks at run time: the check is in the binary, costs a branch on
every access, and when it fails it must do something. In an application it
raises an exception the runtime can unwind. In a kernel there is no such
runtime. The check becomes a trap, and the trap is the end of that core.

Or the question is settled before the binary exists, in which case there is
nothing to check and nothing to trap.

## What C and Rust do about it

**C: no check at all.** The index is an integer, the array is an address.

**Rust: the second answer, and only the second.** `table[index]` is
bounds-checked and panics. That genuinely prevents the memory corruption --
this is not a case where Rust is level with C. What Rust cannot do is remove
the check by *proving* the index, and that matters on bare metal for two
reasons. The panic path is a real outcome in a place with nothing to catch
it: `panic = "abort"` in a kernel means the core stops. And the only way to
delete the check is `get_unchecked`, which is `unsafe` and removes the
question rather than answering it -- it asserts the bound without recording
why anyone believes it.

So the honest comparison is not "Rust is unsafe here". It is that Rust offers
a runtime check or an unchecked access, and a kernel that wants neither has
nowhere to stand.

## What Takibi does

`{lo..<hi as base}` is an integer whose range the type checker knows. An
access proved in range generates no bounds check: the proof is in the type,
so the branch is not in the binary.

An index that is *not* proved still gets a check, because the alternative is
silent corruption. That is the default, and by itself it only moves Takibi
into Rust's position.

`--forbid-trap` is what closes it. Under that flag every remaining trap site
is a compile error, naming each access that still needs a check. The
diagnostic reports both the site and the total, because one unproved access
in a kernel is not a warning about code quality -- it is a trap instruction
that will be in the image.

All maintained kernel `.tkb` code is built under that flag. The consequence
worth stating plainly: the shipped kernel contains no bounds-check trap
because no access needed one, not because the checks were turned off.

Note what the flag does *not* do. It never elides a check to satisfy itself.
It fails the build and leaves the repair to the programmer, which is
refining the type so the caller carries the proof.

## Code that does not compile

```takibi
let mut table: [u32; 64];

fn store(index: usize, value: u32) {
    table[index] = value;
}
```

```text
array bounds check remains: index type usize cannot prove range {0..<64}
Error: --forbid-trap: 1 runtime trap site(s) remain (listed above)
```

Without `--forbid-trap` this program compiles, and the binary contains the
check and the trap. That is the outcome the flag exists to refuse, and it is
the outcome Rust has no way to refuse.

## Code that does compile

```takibi
let mut table: [u32; 64];

fn store(index: {0..<64 as usize}, value: u32) {
    table[index] = value;
}
```

The obligation did not disappear; it moved to the caller, where it is again
either proved or rejected. At the edge of the kernel -- the packet field, the
MMIO word -- it is discharged once, by a check written on purpose, and
everything inward of that carries the proof in its types.

## Limits of this entry

`--forbid-trap` accounts for the trap sites this compiler lowers: array and
subslice bounds, refined casts, exhaustive enum casts. It is a statement about
what the compiler emitted, not a proof that the hardware, the linker script,
or the assembly outside the language model cannot fault.
[`TRUSTED_BASE.md`](../../TRUSTED_BASE.md) states the exact guarantee and what
remains trusted. The named test case pins the accounting -- that this access
records exactly one trap site; that the flag then refuses to build is pinned
by `scripts/buildcheck_wont_compile_samples.py`, which compiles the program
above with it.
