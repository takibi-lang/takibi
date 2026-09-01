---
name: add-takibi-test
description: Choose, add, move, or review a Takibi test in Alcotest, linux_user, or the maintained kernel. Use whenever a task asks for regression coverage, a negative compiler test, an executable language test, a QEMU test, or a hardware-dependent test. Do not use for merely running an existing test suite.
---

# Add a Takibi test

Choose the tier by what the verdict must observe, not by convenience.

## Tier 1: compiler test

Use `test/test_takibi.ml` when the question is compile-time acceptance,
rejection, or generated LLVM shape. These tests never execute the compiled
program. Prefer an in-process `expect_type_error` test for rejection behavior.

`make test` lists every failing Alcotest case through
`scripts/list_dune_test_failures.sh`; Alcotest's ordinary terminal reporter
shows only the first detail box when several cases fail.

## Tier 2: native executable test

Use `linux_user/` when the program must compile and execute, and its verdict
would be identical on real hardware and native Linux/AMD64. Examples include
algorithm results, queue ordering without real concurrency, parsers,
checksums, and runtime confirmation of a type-system prototype.

Run `make linuxbuild` to compile and `make linuxcheck` to execute and compare
stdout with the test's `.expected` fixture.

## Tier 3: maintained kernel

Use `kernel/` with QEMU and RPi5 when the verdict depends on MMIO, real
interrupt timing or latency, physical cache coherence, memory ordering, or
actual concurrency. Do not downgrade such a test to `linux_user/`; a test
that cannot reproduce its target failure is worse than absent coverage.

Use the cheapest kernel lane that preserves the required property. QEMU is
not evidence for physical cache behavior or real timing.

## Build-level negative controls

A negative test executed through `make` or another build command must prove
both facts independently:

1. the command exited nonzero; and
2. output contains the specific expected diagnostic.

Capture status before inspecting output. A missing message alone can mean the
compiler never ran; a present unrelated failure is not the expected rejection.

Do not add new feature tests to the historical `examples/` tree.
