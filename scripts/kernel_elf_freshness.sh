#!/usr/bin/env bash
# Refuse to run a lane against a kernel older than its own sources.
#
# Found the hard way on 2026-09-10. `make kernelbuild` builds the ordinary and
# RPi5 kernels; the oops, DDB, alloc-rollback and lifecycle-gap lanes run
# `kernel-debug.elf`, which only `kernelbuild-check` produces. Running one of
# those lane scripts DIRECTLY -- which is what a person does while debugging
# one -- therefore tests whatever debug kernel was last built.
#
# It cost four runs and a wrong conclusion: the change under test was absent
# from the binary, so a peer's atomics looked incoherent and the design was
# blamed for the build. Nothing said anything; every lane was green about a
# kernel nobody had asked for.
#
# `make` gets this right through the dependency graph. This is for the person
# who bypassed make, and it says which target to run rather than only that
# something is wrong.
kernel_elf_refuse_stale() {
    local elf="$1"
    local label="${2:-$(basename "$elf")}"
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ ! -f "$elf" ]; then
        echo "error: $label does not exist. Build it with" \
             "\`make kernelbuild-check\`." >&2
        return 1
    fi
    local newer
    newer="$(find "$repo_root/kernel" "$repo_root/lib" \
        \( -name '*.tkb' -o -name '*.S' -o -name '*.ld' \) \
        -newer "$elf" -print -quit 2>/dev/null)"
    if [ -n "$newer" ]; then
        echo "error: $label is older than ${newer#$repo_root/}, so this lane" \
             "would test a kernel that does not contain the change under" \
             "test. Build it with \`make kernelbuild-check\` -- \`make" \
             "kernelbuild\` does not produce the debug kernels these lanes" \
             "run." >&2
        return 1
    fi
    return 0
}
