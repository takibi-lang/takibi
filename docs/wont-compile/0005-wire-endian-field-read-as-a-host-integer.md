# 0005. A wire-endian field used as a host integer

| Field | Value |
| --- | --- |
| Status | Enforced |
| Check | type error, wire-endian operators (`lib/type_inf.ml`) |
| Test case | `u16be: ordering comparison is rejected without a cast` |
| Introduced | 2026-08-03, commit `0cf743c9` ("Add u16be, a type-checked big-endian integer type") |
| Specified in | [`SPEC.md`](../../SPEC.md) wire-endian integers |

![The same two bytes read as a big-endian field and as a host integer, giving
opposite answers to one comparison](assets/0005-wire-endian-field-read-as-a-host-integer.svg)

## The defect

Protocol headers and on-disk structures store multi-byte integers in a fixed
byte order, and the core reading them usually uses the other one. Every such
field needs a conversion, and the conversion is invisible: `h->magic` and
`ntohs(h->magic)` are both well-typed expressions of the same type, and only
one of them is right.

Get it wrong and the program does not fault. It computes with a byte-swapped
number. A length comes out enormous, a comparison orders packets backwards, a
checksum fails on some inputs and not others. In the figure, one comparison
between two header fields returns the opposite answer, and nothing anywhere
reports an error.

The failure mode that makes this expensive is portability. Code written and
tested on one endianness can be correct by accident -- the missing conversion
is a no-op there -- and the defect only appears when someone builds for a
different core, years later, in a part of the system nobody associates with
byte order.

## What C and Rust do about it

**C: with an external tool, optionally.** Linux marks these fields
`__be16` and `__be32` via `__bitwise`, and **sparse** reports a mismatch. This
works and it is real, but it is not the compiler: it requires `make C=1` and
sparse installed, so the check is opt-in, out of tree, and absent from an
ordinary build. A codebase that does not run it gets nothing, and `__be16` is
a `u16` again.

**Rust: with a library, if you chose one.** Rust has no language-level
distinction between a wire integer and a host integer. Crates such as
`zerocopy` provide `U16<BigEndian>` newtypes that do prevent arithmetic and
comparison, and they work well. But it is a per-project decision, applied per
field, and a plain `u16` in a `#[repr(C)]` header struct is accepted by the
compiler with no complaint.

So both ecosystems can express this and neither language does. That is a
weaker claim than the rest of this catalog makes, and it is worth stating
precisely: the difference here is not capability, it is where the check lives.
In Takibi it is in the field type of a packed struct, so it applies to every
program the compiler builds, with nothing to opt into and nothing to install.

## What Takibi does

`u16be` and `u32be` are types, not annotations. A field declared with one
holds bytes in wire order, and the checker refuses to treat it as a number.

Arithmetic and ordering comparison are rejected: `<`, `>`, `+` and their
relatives ask a question about magnitude, and the stored bytes do not answer
it on a little-endian core. The diagnostic names the conversion that would.

Equality and the bitwise operators are allowed directly, and that is a
decision rather than an oversight: `==`, `!=`, `&`, `|` and `^` give the same
answer whichever order the bytes are in, so requiring a conversion there would
be ceremony that teaches programmers the conversion is noise.

The conversions themselves are narrow. `u16be` converts to and from `u16`, and
`u32be` to and from `u32`. A cast to any other width is rejected, including
`u16be` to `u32be` -- because a conversion that changes both width and byte
order at once is where the reasoning gets lost.

## Code that does not compile

```takibi
struct packed WireHdr { magic: u16be; flags: u16be; }
fn bad_cmp(h: *WireHdr) -> bool { return h.magic < h.flags; }
```

```text
cannot use a wire-endian (u16be/u32be) value with this operator; convert with
`as u16`/`as u32` first (==, !=, &, |, ^ are allowed directly)
```

## Code that does compile

```takibi
struct packed WireHdr { magic: u16be; flags: u16be; }

fn ordered(h: *WireHdr) -> bool {
    return (h.magic as u16) < (h.flags as u16);
}
```

The cast is the conversion. It is not a way of silencing the checker: `as u16`
is where the byte swap happens, so the program that compiles is also the
program that is correct on both endiannesses.

## Limits of this entry

This covers 16- and 32-bit big-endian integers, which is what the network and
filesystem code in this tree needs. There is no `u64be` and no little-endian
wire type yet; a field of a width the type system does not model is an
ordinary integer again, with the ordinary silence. The check is also about
*use*, not about parsing: it cannot tell you that a header struct describes
the protocol correctly, only that a field you declared as wire-endian is not
being read as though it were not.
