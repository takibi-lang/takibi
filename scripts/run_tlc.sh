#!/usr/bin/env bash
# Give one TLC JVM private standard-module files; the pinned resolver writes
# fixed module names under java.io.tmpdir and deletes them on JVM exit.
set -euo pipefail

tlc_tmp=$(mktemp -d "${TMPDIR:-/tmp}/takibi-tlc.XXXXXX")
trap 'rm -rf "$tlc_tmp"' EXIT
java "-Djava.io.tmpdir=$tlc_tmp" "$@"
