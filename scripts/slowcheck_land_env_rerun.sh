#!/usr/bin/env bash
# GitHub issue #1389: run the land-machinery controls a second time inside a
# simulated land.
#
# slowcheck_resource_lease.sh inherited TAKIBI_LAND_ALLCHECK from the outer
# land and passed only outside one (#1145); the plain slowcheck run never
# sees a land's environment, so it could not catch that. This member runs
# every control scripts/land_env_members.py selects again with the land's
# state planted: TAKIBI_LAND_ALLCHECK=1, a temp TAKIBI_SESSION_REGISTRY whose
# land.lock this shell holds through resource_lease_land_hold (as land.sh
# does), and a temp TAKIBI_LANE_TIMING_DIR that must stay empty afterwards.
#
# Only these members get the environment: exported to every member, it
# would also make them skip the #1145 land wait outside a land.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mapfile -t members < <(python3 "$repo_root/scripts/land_env_members.py")
if [ "${#members[@]}" -eq 0 ]; then
    echo "FAIL land-env-rerun: no land-machinery member selected" >&2
    exit 1
fi

export TAKIBI_SESSION_REGISTRY="$tmp_dir/registry"
export TAKIBI_LANE_TIMING_DIR="$tmp_dir/timing"
mkdir -p "$TAKIBI_LANE_TIMING_DIR"
# shellcheck source=vcpu_lease.sh
. "$repo_root/scripts/vcpu_lease.sh"
TAKIBI_SESSION=simulated-land resource_lease_land_hold simulated
[ "${TAKIBI_LAND_ALLCHECK:-}" = 1 ] || { echo "FAIL land-env-rerun: land hold did not export TAKIBI_LAND_ALLCHECK" >&2; exit 1; }

for member in "${members[@]}"; do
    case "$member" in
        *.sh) runner=(bash "$member");;
        *)    runner=(python3 "$member");;
    esac
    if ! "${runner[@]}" > "$tmp_dir/out" 2>&1; then
        cat "$tmp_dir/out" >&2
        echo "FAIL land-env-rerun: $(basename "$member") failed inside a simulated land" \
             "(TAKIBI_LAND_ALLCHECK=1, land.lock held); it reads the outer land's state (#1389)" >&2
        exit 1
    fi
done

leaked="$(find "$TAKIBI_LANE_TIMING_DIR" -mindepth 1 | head -5)"
if [ -n "$leaked" ]; then
    echo "FAIL land-env-rerun: members wrote into the enclosing TAKIBI_LANE_TIMING_DIR (#914):" >&2
    echo "$leaked" >&2
    exit 1
fi
echo "PASS land-env-rerun: ${#members[@]} land-machinery members inside a simulated land"
