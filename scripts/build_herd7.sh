#!/usr/bin/env bash
# Build herd7 once, outside the repository, for CI's litmus tests (#645).
#
#   bash scripts/build_herd7.sh DEST
#
# installs DEST/bin/herd7 and its model library DEST/share/herdtools7/herd
# (the .cat files herd7 finds through the PREFIX compiled into it, so DEST
# must be the final location: the binary is not relocatable).
#
# Why not `opam install herdtools7` in the CI job: the job's opam switch is
# the local `_opam` inside the checkout, opam builds packages under
# _opam/.opam-switch/build/, and herdtools7's dune then walks up to takibi's
# dune-project as its root and fails ("No rule found for alias
# .../default"). It would also rebuild herdtools7 and its dependencies on
# every run. So CI caches DEST under a key that hashes this file and runs
# this script only on a cache miss (scripts/check_herdtools_pin.py checks
# both).
#
# Isolation. The build uses a private, throwaway OPAMROOT under a temporary
# directory outside the checkout: a fresh OCaml compiler plus dune, menhir
# and zarith. Nothing is written into the job's switch or ~/.opam, so the
# takibi build cannot come to depend on what this pulled in. The cost is a
# compiler build on a miss only.
#
# The pin below must equal the one in .devcontainer/devcontainer.json, where
# development sessions get herd7 from opam (scripts/check_herdtools_pin.py).
set -euo pipefail

HERDTOOLS7_PIN=herdtools7.7.58
HERDTOOLS7_VERSION=${HERDTOOLS7_PIN#herdtools7.}
OCAML_FOR_HERD7=5.4.0

dest=${1:?usage: build_herd7.sh DEST}
case "$dest" in /*) ;; *) echo "build_herd7: DEST must be absolute" >&2; exit 2;; esac
repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
case "$dest/" in "$repo"/*) echo "build_herd7: DEST must be outside the repository" >&2; exit 2;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/build-herd7.XXXXXX")
trap 'rm -rf "$work"' EXIT
case "$work/" in "$repo"/*) echo "build_herd7: temporary directory inside the repository" >&2; exit 2;; esac

export OPAMROOT="$work/opamroot" OPAMYES=1 OPAMCOLOR=never
unset OPAMSWITCH OPAM_SWITCH_PREFIX
opam init --bare --disable-sandboxing --no-setup -q default https://opam.ocaml.org
opam switch create -q herd7 "ocaml-base-compiler.$OCAML_FOR_HERD7"
opam install -q --switch=herd7 --deps-only "$HERDTOOLS7_PIN"

cd "$work"
opam source --switch=herd7 "$HERDTOOLS7_PIN"
cd "herdtools7.$HERDTOOLS7_VERSION"
# Build in a fresh staging prefix, then move into place in one rename, so an
# interrupted build never leaves a half-installed DEST for the cache to keep.
stage="$dest.partial.$$"
rm -rf "$stage"
opam exec --switch=herd7 -- make build PREFIX="$dest"
opam exec --switch=herd7 -- make install PREFIX="$stage"
"$stage/bin/herd7" -version | grep -q "^$HERDTOOLS7_VERSION\b"
mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
mv "$stage" "$dest"
"$dest/bin/herd7" -version
