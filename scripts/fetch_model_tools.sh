#!/usr/bin/env bash
# Fetch the TLA+ model-checking tools at pinned versions, verify them by
# sha256, and print the directory they live in (GitHub issue #601).
#
#   tla2tools.jar  TLC, the explicit-state model checker, and SANY, the parser
#   apalache       the symbolic model checker; here its type checker and a
#                  shallow check, so the specs stay Apalache-ready
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

echo "$root"
