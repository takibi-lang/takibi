#!/usr/bin/env python3
# Verifies examples/fatfs/fatfs.tkb's output image using the host `mtools`
# (mdir/mcopy) as an independent oracle -- fatfs.tkb's own status prints
# only prove the driver THINKS it succeeded; this proves the on-disk bytes
# are a spec-valid FAT12 volume that a real, independent reader agrees with.
# See scripts/run_qemutest.sh's run_fatfs_test, which calls this after
# extracting the image fatfs.tkb wrote out via ARM semihosting.
import re
import subprocess
import sys

# Must match the content examples/fatfs/fatfs.tkb's app_main() writes.
EXPECTED_FILES = {
    "HELLO.TXT": b"Hello, takibi!\r\n",
    "README.TXT": b"fatfs demo file.\r\n",
}


def main():
    if len(sys.argv) != 2:
        print("usage: fatfs_mtools_test.py <disk.img>", file=sys.stderr)
        return 1
    img = sys.argv[1]

    listing = subprocess.run(
        ["mdir", "-i", img, "::"], capture_output=True, text=True
    )
    if listing.returncode != 0:
        print("mdir failed:", listing.stderr, file=sys.stderr)
        return 1

    ok = True
    for name, content in EXPECTED_FILES.items():
        # mdir prints 8.3 names space-padded between the base and extension
        # (e.g. "HELLO    TXT"), not as a dotted "HELLO.TXT" -- match the
        # base/ext/size as a pattern rather than a literal substring.
        base, ext = name.split(".")
        pattern = rf"{re.escape(base)}\s+{re.escape(ext)}\s+{len(content)}\b"
        if not re.search(pattern, listing.stdout):
            print(f"mdir listing missing {name} ({len(content)} bytes):\n{listing.stdout}", file=sys.stderr)
            ok = False
            continue

        extract = subprocess.run(
            ["mcopy", "-i", img, f"::{name}", "-"], capture_output=True
        )
        if extract.returncode != 0:
            print(
                f"mcopy failed for {name}: {extract.stderr.decode(errors='replace')}",
                file=sys.stderr,
            )
            ok = False
            continue
        if extract.stdout != content:
            print(
                f"content mismatch for {name}: expected {content!r}, "
                f"got {extract.stdout!r}",
                file=sys.stderr,
            )
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
