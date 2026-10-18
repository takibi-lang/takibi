#!/usr/bin/env bash
# Fetch the TLA+ model-checking tools at pinned versions, verify them by
# sha256, and print the directory they live in (GitHub issue #601).
#
#   tla2tools.jar  TLC, the explicit-state model checker, and SANY, the parser
#   apalache       the symbolic model checker; here its type checker and a
#                  shallow check, so the specs stay Apalache-ready
#   herdtools7     herd7, which checks litmus tests against the AArch64
#                  memory model (GitHub issue #645); built from source
#
# Where. Outside the repository, so `make clean` (which removes _build/) never
# deletes them. The default is the directory the devcontainer already binds
# from the host for cross-session state (~/.takibi-sessions), so the tools
# survive a container rebuild and every clone on the machine shares one copy.
# Its name is about sessions rather than a cache; the tools sit in their own
# `cache/model-tools/` subtree to keep the two uses apart. Without that
# directory (CI, a machine outside the devcontainer) the fallback is
# ~/.cache/takibi. TAKIBI_MODEL_TOOLS_DIR overrides both.
#
# Concurrency. Several clones may run this at once. Each download goes to a
# private temporary directory, is verified, and is moved into place with one
# rename, so a reader never sees a partial file; a lost race finds the other
# writer's identical copy already there.
#
# Versions and checksums are the whole contract and live only here. The
# Apalache sum is the one its release publishes in sha256sum.txt; tla2tools.jar
# ships none, so its sum was recorded on first download (2026-09-26).
#
# Requires java (21 or later: Apalache 0.62 is built for it), curl, tar and
# sha256sum. Idempotent: with both
# tools present and verified it downloads nothing.
set -euo pipefail

TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_VERSION}/tla2tools.jar"

APALACHE_VERSION=0.62.2
APALACHE_SHA256=765f610537281a0f25b8c30f2554f19523e2859c824e80e62276653ee23c10e2
HERD_VERSION=7.58
# GitHub's tag archive; recorded on first download (2026-10-18).
HERD_SHA256=1b72798457e678dec781ce914c4bd84dc6bae3c3c044cf4257d0974bf7f066ad
HERD_URL="https://github.com/herd/herdtools7/archive/refs/tags/${HERD_VERSION}.tar.gz"
# herdtools7's build dependencies, at the versions it was first built with.
HERD_OPAM_DEPS="dune.3.22.0 menhir.20260209 zarith.1.14"

APALACHE_URL="https://github.com/apalache-mc/apalache/releases/download/v${APALACHE_VERSION}/apalache-${APALACHE_VERSION}.tgz"

if [ -n "${TAKIBI_MODEL_TOOLS_DIR:-}" ]; then
    root="$TAKIBI_MODEL_TOOLS_DIR"
elif [ -d "$HOME/.takibi-sessions" ]; then
    root="$HOME/.takibi-sessions/cache/model-tools"
else
    root="${XDG_CACHE_HOME:-$HOME/.cache}/takibi/model-tools"
fi
mkdir -p "$root"

for tool in java curl tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "fetch_model_tools: $tool is required and was not found" >&2
        exit 1
    }
done

verify() {  # file expected-sha256
    [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}

tla_dir="$root/tla2tools-$TLA_VERSION"
if [ ! -f "$tla_dir/tla2tools.jar" ] ||
   ! verify "$tla_dir/tla2tools.jar" "$TLA_SHA256"; then
    work="$(mktemp -d "$root/.tla2tools.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/tla2tools.jar" "$TLA_URL"
    if ! verify "$work/tla2tools.jar" "$TLA_SHA256"; then
        echo "fetch_model_tools: tla2tools.jar $TLA_VERSION failed its sha256 check" >&2
        exit 1
    fi
    rm -rf "$tla_dir.stale"
    [ -e "$tla_dir" ] && mv "$tla_dir" "$tla_dir.stale"
    mv "$work" "$tla_dir" 2>/dev/null || rm -rf "$work"
    rm -rf "$tla_dir.stale"
    trap - EXIT
fi

apalache_dir="$root/apalache-$APALACHE_VERSION"
if [ ! -x "$apalache_dir/bin/apalache-mc" ]; then
    work="$(mktemp -d "$root/.apalache.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/apalache.tgz" "$APALACHE_URL"
    if ! verify "$work/apalache.tgz" "$APALACHE_SHA256"; then
        echo "fetch_model_tools: apalache $APALACHE_VERSION failed its sha256 check" >&2
        exit 1
    fi
    tar -xzf "$work/apalache.tgz" -C "$work"
    # The archive holds one top-level directory, apalache-<version>/.
    mv "$work/apalache-$APALACHE_VERSION" "$apalache_dir" 2>/dev/null || true
    rm -rf "$work"
    trap - EXIT
    [ -x "$apalache_dir/bin/apalache-mc" ] || {
        echo "fetch_model_tools: apalache $APALACHE_VERSION unpacked without bin/apalache-mc" >&2
        exit 1
    }
fi

# WORK IN PROGRESS (#645), KNOWN FAILING: `opam switch create herd
# ocaml-system.<v>` in a fresh private root fails, since opam there cannot see
# sys-ocaml-version. Next candidate: build zarith 1.14 (sha256
# 5db9dcbd939153942a08581fabd846d0f3f2b8c67fe68b855127e0472d4d1859, from
# github.com/ocaml/Zarith release-1.14) with `./configure -installdir
# <private findlib dir>` (WITHOUT it, its `make install` writes into the
# shared switch) and build herdtools7 with OCAMLPATH pointing there. CI
# (.github/workflows/ci.yml) caches the model-tools root keyed on this file.
#
# herdtools7 (GitHub issue #645). opam has it, but installing into the
# developer's shared opam switch is not allowed, and that switch lacks zarith.
# So the build uses a PRIVATE opam root inside a temporary directory, with an
# `ocaml-system` switch that reuses the ocaml already on PATH (no compiler
# build), installs the pinned dependencies there, and builds the
# sha256-checked source tarball. herd7 bakes its library directory in at
# build time, so it is built and installed with the final prefix, under a
# lock, rather than renamed into place.
# Requires opam, ocaml, make, flock and libgmp's headers.
herd_dir="$root/herdtools7-$HERD_VERSION"
if [ ! -x "$herd_dir/bin/herd7" ]; then
    for tool in opam ocaml make flock; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "fetch_model_tools: $tool is required to build herdtools7" >&2
            exit 1
        }
    done
    exec 9>"$root/.herdtools7.lock"
    flock 9
    if [ ! -x "$herd_dir/bin/herd7" ]; then
        work="$(mktemp -d "$root/.herdtools7.XXXXXX")"
        trap 'rm -rf "$work"' EXIT
        curl -fsSL -o "$work/herdtools7.tgz" "$HERD_URL"
        if ! verify "$work/herdtools7.tgz" "$HERD_SHA256"; then
            echo "fetch_model_tools: herdtools7 $HERD_VERSION failed its sha256 check" >&2
            exit 1
        fi
        tar -xzf "$work/herdtools7.tgz" -C "$work"
        log="$work/build.log"
        if ! (
            export OPAMROOT="$work/opam" OPAMYES=1 OPAMCOLOR=never
            unset OPAMSWITCH OPAM_SWITCH_PREFIX
            opam init --bare --no-setup --disable-sandboxing -q
            opam switch create herd "ocaml-system.$(ocamlc -vnum)" -q
            # shellcheck disable=SC2086
            opam install --switch=herd -q $HERD_OPAM_DEPS
            cd "$work/herdtools7-$HERD_VERSION"
            rm -rf "$herd_dir"
            opam exec --switch=herd -- make build PREFIX="$herd_dir"
            opam exec --switch=herd -- make install PREFIX="$herd_dir"
        ) >"$log" 2>&1; then
            tail -n 40 "$log" >&2
            rm -rf "$herd_dir"
            echo "fetch_model_tools: building herdtools7 $HERD_VERSION failed" >&2
            exit 1
        fi
        rm -rf "$work"
        trap - EXIT
    fi
    flock -u 9
    [ -x "$herd_dir/bin/herd7" ] || {
        echo "fetch_model_tools: herdtools7 $HERD_VERSION installed without bin/herd7" >&2
        exit 1
    }
fi

echo "$root"
