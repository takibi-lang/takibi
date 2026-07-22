#!/usr/bin/env bash
# Shared helper for saving test logs under target-specific artifact roots.

sanitize_artifact_name() {
    printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}

save_artifact_file() {
    local root="$1" name="$2" src="$3" dest_name="${4:-uart.log}"
    local safe_name artifact_dir

    [ -n "$root" ] || return 0
    [ -n "$name" ] || return 0
    [ -f "$src" ] || return 0

    safe_name=$(sanitize_artifact_name "$name")
    artifact_dir="$root/$safe_name"
    mkdir -p "$artifact_dir"
    cp "$src" "$artifact_dir/$dest_name"
}
