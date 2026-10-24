#!/usr/bin/env bash
# Opt-in profiling switch for #917: OCaml 5.4.0 with frame pointers, so
# `perf record --call-graph=fp` sees through OCaml frames. Run by hand when
# profiling; postCreateCommand does not run it (it takes tens of minutes).
#
# The switch is a local (directory) switch in the host-bound session
# directory, beside the model tools (scripts/fetch_model_tools.sh), so it
# survives container rebuilds and every clone shares one copy. ~/.opam does
# not survive: it is part of the container and postCreateCommand rebuilds the
# default switch. It lives outside the workspace so dune never walks into its
# _opam. An opam switch embeds its absolute path, so the path stays fixed.
#
# Use:  eval $(opam env --switch=/home/vscode/.takibi-sessions/cache/opam-fp --set-switch)
set -euo pipefail

dir=/home/vscode/.takibi-sessions/cache/opam-fp
# The project's own dependencies come from dune-project (as in ci.yml); the
# rest are the profilers.
packages=(landmarks landmarks-ppx memtrace runtime_events_tools)

if [ ! -d "$dir/_opam" ]; then
  opam switch create "$dir" --no-install \
    --packages=ocaml-variants.5.4.0+options,ocaml-option-fp
fi
cd "$(dirname "$0")/.."
opam install --switch="$dir" -y --deps-only --with-test .
opam install --switch="$dir" -y "${packages[@]}"
opam exec --switch="$dir" -- ocamlopt -config | grep '^with_frame_pointers: true'
