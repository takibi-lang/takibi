#!/usr/bin/env python3
"""Refuse a kernel in which a pool has no way to give a record back.

GitHub issue #414 found this shape by measurement, not by reading:
`address_space_backing_pool` had no `intrusive_pool_remove` call anywhere.
Every process that got an address-space root permanently consumed one
`AddressSpaceBacking`, unreachable the moment the `ProcessRecord` naming it
was recycled -- 17 of them in a single QEMU boot. It was invisible to the
page check (`resources: pages=0`), because a pool keeps its chunk page
whether or not the record inside it came back, and it was invisible to
review because the file SAID so: "Nothing releases", inherited from the
array that pool replaced.

The shape is what a `grep` can see: a pool is declared, and nothing ever
removes from it. That is not always a bug -- a pool whose records really do
live for the whole run is legitimate -- so a pool may opt out with a
comment on its declaration line saying why:

    private let mut forever_pool: IntrusivePool(T);  // never-released: <reason>

which is a claim a reviewer can disagree with, where silence was not.

Scope is kernel/ only. linux_user/ exercises the primitives directly and
its fixtures legitimately allocate without giving back.
"""

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO_ROOT / "kernel"

DECL = re.compile(
    r"^\s*(?:private\s+)?let\s+mut\s+(?P<name>[a-z_0-9]+)\s*:\s*IntrusivePool\((?P<payload>[A-Za-z_0-9]+)\)\s*;(?P<trailing>.*)$"
)
OPT_OUT = re.compile(r"//\s*never-released:\s*\S")


def main() -> int:
    sources = sorted(KERNEL.rglob("*.tkb"))
    texts = {path: path.read_text(encoding="utf-8") for path in sources}
    pools = []
    for path, text in texts.items():
        for line in text.splitlines():
            match = DECL.match(line)
            if match:
                pools.append(
                    (
                        path,
                        match.group("name"),
                        match.group("payload"),
                        bool(OPT_OUT.search(match.group("trailing"))),
                    )
                )

    if not pools:
        print("ERROR\tno IntrusivePool declarations found -- has the spelling changed?")
        return 1

    failed = False
    exempt = 0
    for path, name, payload, opted_out in pools:
        if opted_out:
            exempt += 1
            continue
        removal = f"intrusive_pool_remove(&{name},"
        if not any(removal in text for text in texts.values()):
            rel = path.relative_to(REPO_ROOT)
            print(
                f"ERROR\t{rel}: pool `{name}` (IntrusivePool({payload})) has no "
                f"`{removal}` anywhere in kernel/ -- every record it hands out is "
                "kept for the life of the kernel.\n"
                "\tGive it a release path, or say why it does not need one with a "
                "`// never-released: <reason>` comment on its declaration."
            )
            failed = True

    if failed:
        print("FAIL pool-release-paths: a pool hands out records it can never take back")
        return 1
    print(
        f"PASS pool-release-paths: {len(pools)} pools, "
        f"{len(pools) - exempt} with a release path, {exempt} declared never-released"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
