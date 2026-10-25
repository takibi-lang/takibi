#!/usr/bin/env python3
"""Judge the ext2 disk a QEMU guest left behind, with the host's e2fsprogs.

GitHub issue #1033 (ext2 equivalence, tier A: structure). Every QEMU lane
hands the guest a copy of the rootfs image as a file, so after the run the
host's own tools can read what the kernel wrote. This is the one place that
reading happens; every runner whose guest gets a writable disk calls it
(scripts/check_ext2_postcheck_lanes.py refuses one that does not).

It checks, in order:

1. `e2fsck -fn` passes (#537): the structure is ext2.
2. The free counters agree. The kernel keeps no cached copy of them:
   `ext2_free_counts` and `ext2_update_free_counts` read and write the
   on-disk superblock and group descriptor on every call, so the superblock
   and descriptor ARE the kernel's own accounting. They are compared with
   each other and with the counts the block and inode bitmaps give, so a
   leak or a double free -- a bitmap bit and a counter that moved apart, the
   shape of #1020 / #1021 -- is caught as a number even when it is named.
3. Every `resource exhausted: ext2 blocks capacity=N` line the guest printed
   names the block count the host reads from the superblock.
4. The lane's own presence facts (`--grown-dir`, `--indirect-dir`, `--dir`),
   so a lane that asserts its workload ran is known to be reading the
   structure it wrote. `--indirect-dir` is a directory grown past its twelve
   direct blocks into the singly-indirect block (#968).
5. The known divergences in scripts/ext2_known_divergences.tsv: a fact that
   holds only once the named issue is fixed. A row whose subject is on the
   disk and whose fact now holds FAILS, so the fix flips the row instead of
   passing silently (#998). A row whose subject is absent was not reached
   by this lane's workload and is reported as such.

`--report-only` prints the verdict and exits 0, for the interactive shell,
whose disk a person may leave mid-write.
"""

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIVERGENCES = ROOT / "scripts/ext2_known_divergences.tsv"
CAPACITY = re.compile(rb"resource exhausted: ext2 blocks capacity=(\d+)")


def run(argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    return result.returncode, result.stdout.decode("utf-8", "replace")


def range_count(text):
    total = 0
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        low, _, high = part.partition("-")
        total += int(high or low) - int(low) + 1
    return total


def parse_dumpe2fs(text):
    """Superblock totals, per-group descriptor counts, per-group bitmap counts."""
    def header(name):
        match = re.search(rf"^{name}:\s+(\d+)$", text, re.M)
        if match is None:
            raise ValueError(f"dumpe2fs printed no '{name}:' line")
        return int(match.group(1))

    groups = []
    for block in re.split(r"^Group \d+:", text, flags=re.M)[1:]:
        counts = re.search(r"^\s+(\d+) free blocks, (\d+) free inodes,",
                           block, re.M)
        free_blocks = re.search(r"^\s+Free blocks: ?(.*)$", block, re.M)
        free_inodes = re.search(r"^\s+Free inodes: ?(.*)$", block, re.M)
        if counts is None or free_blocks is None or free_inodes is None:
            raise ValueError("dumpe2fs printed a group without its counts")
        groups.append((int(counts.group(1)), int(counts.group(2)),
                       range_count(free_blocks.group(1)),
                       range_count(free_inodes.group(1))))
    if not groups:
        raise ValueError("dumpe2fs printed no group")
    return {"block_count": header("Block count"),
            "free_blocks": header("Free blocks"),
            "free_inodes": header("Free inodes"),
            "groups": groups}


def counter_problems(layout):
    found = []
    groups = layout["groups"]
    for kind, sb, desc_index, bitmap_index in (
            ("blocks", layout["free_blocks"], 0, 2),
            ("inodes", layout["free_inodes"], 1, 3)):
        descriptors = sum(group[desc_index] for group in groups)
        bitmaps = sum(group[bitmap_index] for group in groups)
        if not sb == descriptors == bitmaps:
            found.append(f"free {kind}: superblock {sb}, group descriptors "
                         f"{descriptors}, bitmaps {bitmaps}")
        for number, group in enumerate(groups):
            if group[desc_index] != group[bitmap_index]:
                found.append(f"group {number} free {kind}: descriptor "
                             f"{group[desc_index]}, bitmap {group[bitmap_index]}")
    return found


def load_divergences(path=DIVERGENCES):
    rows = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or (line.startswith("#")
                                   and not re.match(r"#\d+\t", line)):
            continue
        fields = line.split("\t")
        if len(fields) != 4 or not re.fullmatch(r"#\d+", fields[0]):
            raise ValueError(f"{path.name}:{number}: want 'issue<TAB>path"
                             "<TAB>regex-of-the-fixed-stat<TAB>reason'")
        rows.append({"issue": fields[0], "path": fields[1],
                     "fixed": re.compile(fields[2], re.M),
                     "reason": fields[3]})
    return rows


def stat(image, path):
    status, text = run(["debugfs", "-R", f"stat {path}", str(image)])
    present = status == 0 and re.search(r"^Inode: \d+", text, re.M) is not None
    return present, text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--label", required=True)
    parser.add_argument("--image", required=True, type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--uart-log", type=pathlib.Path)
    parser.add_argument("--grown-dir", action="append", default=[],
                        help="a directory the workload grew past one block")
    parser.add_argument("--indirect-dir", action="append", default=[],
                        help="a directory the workload grew through an "
                             "indirect block")
    parser.add_argument("--dir", action="append", default=[],
                        help="a directory the workload made and kept")
    parser.add_argument("--divergences", type=pathlib.Path,
                        default=DIVERGENCES)
    parser.add_argument("--report-only", action="store_true")
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)

    failures = []
    notes = []
    if not args.image.is_file():
        failures.append(f"no disk image at {args.image}")
    else:
        status, text = run(["e2fsck", "-fn", str(args.image)])
        (args.out / "e2fsck.log").write_text(text)
        if status != 0:
            failures.append("e2fsck rejected the disk the guest wrote:\n"
                            + "".join(f"  {line}\n"
                                      for line in text.splitlines()))
        status, text = run(["dumpe2fs", str(args.image)])
        (args.out / "dumpe2fs.log").write_text(text)
        layout = None
        if status != 0:
            failures.append("dumpe2fs could not read the disk")
        else:
            try:
                layout = parse_dumpe2fs(text)
            except ValueError as error:
                failures.append(str(error))
        if layout is not None:
            failures.extend("counters disagree: " + problem
                            for problem in counter_problems(layout))
            if args.uart_log is not None and args.uart_log.is_file():
                for match in CAPACITY.finditer(args.uart_log.read_bytes()):
                    printed = int(match.group(1))
                    if printed != layout["block_count"]:
                        failures.append(
                            f"guest printed ext2 blocks capacity={printed}, "
                            f"superblock block count {layout['block_count']}")
        for path in args.grown_dir:
            present, text = stat(args.image, path)
            size = re.search(r"^User:.*Size: (\d+)$", text, re.M)
            if not present or size is None or int(size.group(1)) <= 1024:
                failures.append(f"{path} on the guest's disk is not past one "
                                f"block (size {size.group(1) if size else '?'})")
        for path in args.indirect_dir:
            present, text = stat(args.image, path)
            size = re.search(r"^User:.*Size: (\d+)$", text, re.M)
            if (not present or "Type: directory" not in text
                    or size is None or int(size.group(1)) <= 12 * 1024
                    or "(IND)" not in text):
                failures.append(f"{path} on the guest's disk is not a "
                                "directory grown through an indirect block "
                                f"(size {size.group(1) if size else '?'})")
        for path in args.dir:
            present, text = stat(args.image, path)
            if not present or "Type: directory" not in text:
                failures.append(f"{path} is not a directory on the guest's disk")
        try:
            rows = load_divergences(args.divergences)
        except (OSError, ValueError) as error:
            rows = []
            failures.append(str(error))
        for row in rows:
            present, text = stat(args.image, row["path"])
            if not present:
                notes.append(f"{row['issue']} {row['path']}: not reached by "
                             "this lane's workload")
            elif row["fixed"].search(text):
                failures.append(
                    f"{row['issue']} {row['path']}: the known divergence no "
                    f"longer shows ({row['reason']}); if {row['issue']} is "
                    "fixed, remove its row from "
                    "scripts/ext2_known_divergences.tsv")
            else:
                notes.append(f"{row['issue']} {row['path']}: still divergent, "
                             "as recorded")

    lines = [f"ext2 postcheck {args.label}: "
             + ("FAIL" if failures else "ok")]
    lines += [f"  note: {note}" for note in notes]
    lines += [f"  FAIL: {failure}" for failure in failures]
    (args.out / "ext2-postcheck.txt").write_text("\n".join(lines) + "\n")
    if failures:
        stream = sys.stdout if args.report_only else sys.stderr
        for line in lines:
            print(line, file=stream)
        return 0 if args.report_only else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
