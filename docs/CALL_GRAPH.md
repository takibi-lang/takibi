# The call-graph table

`takibi ... --emit-call-graph PATH` writes the program's resolved call graph
as a tab-separated table, after type checking. It exists so a build check
that asks "which function calls which" reads the compiler's own answer
instead of re-deriving it from `.tkb` text with regular expressions. A
regex over source stops matching without failing; this table cannot drift
from what the compiler resolved, because it is that resolution.

The kernel recipes in the root `Makefile` (the QEMU and RPi5 `main.o`) and
the EL0 payload macro `KERNEL_EL0_COMPILE` write it beside the object as
`<object>.callgraph.tsv`, and the checks that need it run from the same
recipe on that file. `scripts/call_graph_table.py` is the Python reader; it
refuses another format version, a changed column set and an empty table.

Without the flag the compiler does no work for it: the parser records
definition ends only while the flag is set.

## Format, version 1

The first line is

    # takibi call graph, format 1; see docs/CALL_GRAPH.md

and the second names the columns. Each later line is one function
definition. A cell that holds a list separates its items with `,`; an
empty cell or empty list is `-`.

| column | content |
| --- | --- |
| `file` | the definition's source file, relative to the compiler's working directory when it is under it; `<builtin region>` and `<protocol NAME>` for definitions the compiler generates |
| `line` | the line of the definition's first token (`private`, `inline`, `noinline` or `fn`) |
| `end_line` | the line of its closing brace; `-` for a generated definition |
| `name` | the source name; a generic function's instances are one row under the template's name |
| `qualifiers` | the subset of `private`, `inline`, `noinline` |
| `declared` | the declared effect contract: `-` when there is none, `{}` for an explicit empty one, else its effects as written |
| `effects` | the effects the checker inferred, with declared roles, sorted (the effect names of `EFFECTS.md`); the union over a generic function's instances |
| `params` | `name: type` per parameter, separated by `, `. The type is spelled from the compiler's tokens with a blank only between two word-like tokens (`borrow Ext2MutationGuard[ext2_mutation_lock]`, `&mut T`, `[u8;4]`), so `, ` never occurs inside one |
| `callees` | the resolved direct callees, deduplicated and sorted, each `name@file:line` naming the callee's own row, or `name@-` for a callee with no definition here (an `extern`); `*` when the function also calls through a function value, whose target is not known |
| `callers` | the rows whose `callees` name this one, spelled the same way |
| `values` | the functions this one names as a value (passes, stores or returns a function pointer to), spelled the same way |
| `body_hash` | the MD5 digest, in hex, of the definition's tokens from the compiler's own lexer, joined by blanks: comments and layout do not move it, any token change does, including one inside a string literal or the signature; `-` for a generated definition |

Rows come in the order the definitions reach the type checker. Calls in a
global or constant initializer belong to no row.

What the table does not say: the targets of an indirect call (the effect
contracts in `effect_rules.ml` constrain those), anything about `extern`
declarations beyond their name, and a generic function that is never
instantiated (it has no compiled body and no row).

## Changing the format

A column is added when a consumer needs it, and the version goes up with
any change a reader could misread -- a new, removed or reordered column, or
a cell's spelling. `scripts/call_graph_table.py` and every check that reads
the table change in the same commit.

## Readers

- `scripts/buildcheck_ext2_mutation_guard.py`: `callees` and `params`.
- `scripts/buildcheck_model_function_map.py`: `name`, `body_hash` (the
  review stamps), `callees`, and `file`/`line`/`end_line` to read one
  guard function's own lines for its `KernelActivity` argument. It reads
  the QEMU and the RPi5 table together.
