#!/usr/bin/env python3
"""Refuse a kernel in which a pool has no way to give a record back.

GitHub issue #414 found this shape by measurement, not by reading:
`address_space_backing_pool` had no release call anywhere. Every process
that got an address-space root permanently consumed one
`AddressSpaceBacking`, unreachable the moment the `ProcessRecord` naming it
was recycled -- 17 of them in a single QEMU boot. It was invisible to the
page check (`resources: pages=0`), because a pool keeps its chunk page
whether or not the record inside it came back, and it was invisible to
review because the file SAID so: "Nothing releases", inherited from the
array that pool replaced.

Every kernel pool is the built-in RegionPool since GitHub issue #745
removed IntrusivePool from the kernel. A pool `name: RegionPool(T)` has a
release path when some kernel function calls `region_free(` or
`region_retire(` and names that pool (`&name`) or its element type in a
RegionPool type (`RegionPoolGuard(T)`, `RegionSlot(T)`, `RegionPin(T)`,
`RegionPinned(T)`, `RegionTake(T)`, `RegionRetire(T)`,
`RegionReleaseSlot(T)`). That is not always a bug -- a pool whose records
really do live for the whole run is legitimate -- so a pool may opt out
with a comment on its declaration line saying why:

    private let mut forever_pool: RegionPool(T);  // never-released: <reason>

which is a claim a reviewer can disagree with, where silence was not.

Scope is kernel/ only. linux_user/ exercises the primitives directly and
its fixtures legitimately allocate without giving back.
"""

import pathlib
import re
import sys

from pass_line import report_pass

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO_ROOT / "kernel"

DECL = re.compile(
    r"^\s*(?:private\s+)?let\s+mut\s+(?P<name>[a-z_0-9]+)\s*:\s*RegionPool\((?P<payload>[A-Za-z_0-9]+)\)\s*;(?P<trailing>.*)$"
)
OPT_OUT = re.compile(r"//\s*never-released:\s*\S")
FUNCTION = re.compile(r"^(?:private )?(?:inline |noinline )?fn \w+", re.M)
RELEASE = re.compile(r"\bregion_(?:free|retire)\(")
TYPED = re.compile(
    r"\bRegion(?:PoolGuard|Slot|Pin|Pinned|Take|Retire|ReleaseSlot)\((\w+)\)")
NAMED = re.compile(r"&([a-z_0-9]+)")


def functions(text):
    code = "\n".join(line.split("//", 1)[0] for line in text.splitlines())
    starts = [match.start() for match in FUNCTION.finditer(code)]
    return [code[start:(starts[i + 1] if i + 1 < len(starts) else len(code))]
            for i, start in enumerate(starts)]


def main() -> int:
    sources = sorted(KERNEL.rglob("*.tkb"))
    texts = {path: path.read_text(encoding="utf-8") for path in sources}
    pools = []
    released_types, released_names = set(), set()
    for path, text in texts.items():
        for line in text.splitlines():
            match = DECL.match(line)
            if match:
                pools.append((path, match.group("name"), match.group("payload"),
                              bool(OPT_OUT.search(match.group("trailing")))))
        for body in functions(text):
            if RELEASE.search(body):
                released_types.update(TYPED.findall(body))
                released_names.update(NAMED.findall(body))

    if not pools:
        print("ERROR\tno RegionPool declarations found -- has the spelling changed?")
        return 1

    failed = False
    exempt = 0
    for path, name, payload, opted_out in pools:
        if opted_out:
            exempt += 1
            continue
        if payload not in released_types and name not in released_names:
            rel = path.relative_to(REPO_ROOT)
            print(
                f"ERROR\t{rel}: pool `{name}` (RegionPool({payload})) has no "
                "region_free or region_retire naming it or its element type "
                "anywhere in kernel/ -- every record it hands out is kept for "
                "the life of the kernel.\n"
                "\tGive it a release path, or say why it does not need one with a "
                "`// never-released: <reason>` comment on its declaration."
            )
            failed = True

    if failed:
        print("FAIL pool-release-paths: a pool hands out records it can never take back")
        return 1
    report_pass(
        "pool-release-paths",
        f"{len(pools)} pools, {len(pools) - exempt} with a release path, "
        f"{exempt} declared never-released",
        pools=len(pools),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
