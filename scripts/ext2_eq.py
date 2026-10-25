#!/usr/bin/env python3
"""ext2 equivalence, tier B (GitHub issue #1034): one operation script,
replayed by the kernel and by host Linux, compared logically on disk.

The operation script (kernel/tests/ext2_eq/ops.eq) is a list of rows. Each
row names the issue it stands for and whether the kernel's result is
expected to MATCH the oracle or to DIFFER from it (a known, open
divergence). The verdict is per row, and an unexpected outcome in either
direction fails: a fix flips its row in the same commit, and a regression
of a matching row is caught.

Two oracles, never a hand:

- syscall semantics: host Linux. The generated shell script runs under the
  pinned aarch64 BusyBox through qemu-aarch64 (user mode, so every syscall
  is the host Linux kernel's) on a scratch directory. Its log -- each
  operation's exit status and the type of the path afterwards -- is the
  expected log. `host` regenerates it and `check-expected` refuses a
  committed kernel/tests/ext2_eq/host.expected that differs (linuxcheck).
- on-disk result: libext2fs. The tree host Linux left (types, modes,
  sizes, contents, hard links) is written with `debugfs -w` onto a copy of
  the pristine fixture image, under the image build's fixed
  E2FSPROGS_FAKE_TIME. The kernel's image is the lane's disk after the
  guest ran the same script.

`compare` judges each row on: its log lines against the host log; and,
for every path under the row's directory in both images, type, mode, size,
link count, i_blocks (regular files) and content bytes, plus the set of
names in each directory. Byte-identical images are not required: block
numbers and directory sizes are the allocator's choice. Times are not
compared. Two whole-image rows close the comparison: the superblock and
group-descriptor free counts equal the bitmaps' (`counters`), and every
allocated block and inode is reachable from the tree (`conservation`:
free blocks in the bitmap plus the 1 KiB blocks of every reachable inode
is the same number in both images, and likewise for inodes), which is
where a block leaked by an unlink or truncate shows.

Usage:
  ext2_eq.py gen-sh OPS OUT                 the guest/host shell script
  ext2_eq.py host OPS BUSYBOX WORKDIR       run it on host Linux; prints log
  ext2_eq.py check-expected OPS BUSYBOX EXPECTED
  ext2_eq.py replay OPS BUSYBOX PRISTINE OUT
  ext2_eq.py compare OPS EXPECTED KERNEL_IMAGE HOST_IMAGE
  ext2_eq.py self-test
"""

import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

from pass_line import report_pass

ROOT = "eq"          # the subtree every row lives under, on both sides
LOG = "eq-log"       # the guest's log, beside ROOT in the image root
FAKE_TIME = "1700000000"
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$")
TEXT_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
LONG = "n" * 200     # a long entry name: four to a 1 KiB directory block


class EqError(Exception):
    pass


# ---------------------------------------------------------------- parsing

OPS = {
    # op: (argument kinds, shell template)
    "mkdir": (("path",), 'mkdir "$R/{0}"'),
    "rmdir": (("path",), 'rmdir "$R/{0}"'),
    "write": (("path", "text"), '$B echo -n {1} >"$R/{0}"'),
    "fill": (("path", "count"), None),
    "overwrite": (("path", "path"), '$B dd if="$R/{1}" of="$R/{0}" conv=notrunc 2>/dev/null'),
    "unlink": (("path",), 'rm "$R/{0}"'),
    "rename": (("path", "path"), 'mv "$R/{0}" "$R/{1}"'),
    "files": (("path", "count"), None),
}


def parse(text):
    """Rows as (name, expect, issue, [(lineno, op, args)])."""
    rows = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        words = line.split()
        if words[0] == "row":
            if len(words) != 4 or words[2] not in ("match", "differ") or \
                    not re.fullmatch(r"#[0-9]+|-", words[3]) or \
                    not TEXT_RE.match(words[1]):
                raise EqError(f"line {lineno}: want 'row NAME match|differ #ISSUE|-'")
            if any(r[0] == words[1] for r in rows):
                raise EqError(f"line {lineno}: row {words[1]} named twice")
            rows.append((words[1], words[2], words[3], []))
            continue
        if not rows:
            raise EqError(f"line {lineno}: an operation before the first row")
        op, args = words[0], words[1:]
        if op not in OPS:
            raise EqError(f"line {lineno}: unknown operation {op!r}")
        kinds = OPS[op][0]
        if len(args) != len(kinds):
            raise EqError(f"line {lineno}: {op} takes {len(kinds)} arguments")
        row = rows[-1][0]
        for kind, arg in zip(kinds, args):
            if kind == "path" and not (NAME_RE.match(arg) and
                                       (arg == row or arg.startswith(row + "/"))):
                raise EqError(f"line {lineno}: path {arg!r} is not under row {row}/")
            if kind == "text" and not TEXT_RE.match(arg):
                raise EqError(f"line {lineno}: text {arg!r} is not [A-Za-z0-9_.-]+")
            if kind == "count" and not re.fullmatch(r"[0-9]{1,4}", arg):
                raise EqError(f"line {lineno}: count {arg!r}")
        rows[-1][3].append((lineno, op, args))
    if not rows:
        raise EqError("no rows")
    return rows


# ------------------------------------------------------------ shell script

def gen_sh(rows):
    """One POSIX shell script for both sides. It uses no pipe, command
    substitution or lseek, which the kernel does not offer, and logs only
    what does not depend on the side: the row, the operation, its status,
    and the path's type afterwards."""
    out = [
        "# Generated by scripts/ext2_eq.py gen-sh from kernel/tests/ext2_eq/ops.eq",
        "# (GitHub issue #1034). Do not edit; edit ops.eq.",
        'R="$1/' + ROOT + '"',
        # applets /bin does not link are run through the multicall binary on
        # the guest; on the host BusyBox runs them in-process (B empty)
        'B="${2-/bin/busybox}"',
        'mkdir "$R"',
        # one 1 KiB block of zeros, the unit `fill` concatenates
        '$B printf %01024d 0 >"$R/k"',
        "t() { if [ -d \"$1\" ]; then echo \"  $2 dir\"; elif [ -f \"$1\" ]; "
        "then $B stat -c \"  $2 file size=%s\" \"$1\"; else echo \"  $2 absent\"; fi; }",
    ]
    for name, _expect, _issue, ops in rows:
        out.append(f"echo 'row {name}'")
        for step, (_lineno, op, args) in enumerate(ops, 1):
            label = f"{step} {op} {' '.join(args)}"
            if op == "fill":
                cmd = 'cat ' + " ".join(['"$R/k"'] * int(args[1])) + f' >"$R/{args[0]}"'
            elif op == "files":
                cmd = (f'i=0; ok=0; while [ $i -lt {args[1]} ]; do '
                       f'$B true >"$R/{args[0]}/{LONG}$i" 2>/dev/null && ok=$((ok+1)); '
                       f'i=$((i+1)); done; [ $ok -eq {args[1]} ]')
                out.append(cmd)
                out.append(f'echo "{label} -> $? created=$ok"')
                out.append(f't "$R/{args[0]}" {args[0]}')
                continue
            else:
                cmd = OPS[op][1].format(*args)
            out.append(f"{cmd} 2>/dev/null")
            out.append(f'echo "{label} -> $?"')
            for arg, kind in zip(args, OPS[op][0]):
                if kind == "path":
                    out.append(f't "$R/{arg}" {arg}')
    out.append("echo 'eq done'")
    return "\n".join(out) + "\n"


# ----------------------------------------------------------- host oracle

def qemu_user():
    for name in ("qemu-aarch64", "qemu-aarch64-static"):
        found = shutil.which(name)
        if found:
            return found
    raise EqError("qemu-aarch64 (qemu-user) is required for the host oracle")


def run_host(rows, busybox, workdir):
    """Run the script on host Linux in WORKDIR; return the log."""
    script = os.path.join(workdir, "ext2-eq.sh")
    with open(script, "w") as handle:
        handle.write(gen_sh(rows))
    tree = os.path.join(workdir, "root")
    os.mkdir(tree)
    done = subprocess.run([qemu_user(), busybox, "ash", script, tree, ""],
                          preexec_fn=lambda: os.umask(0o022),
                          capture_output=True, text=True, timeout=120)
    if done.returncode != 0 or not done.stdout.endswith("eq done\n"):
        raise EqError(f"host run failed (status {done.returncode}): {done.stderr}")
    return done.stdout, tree


# --------------------------------------------------------- libext2fs side

def debugfs(image, commands, write=False):
    """Run debugfs commands in one process; return stdout."""
    with tempfile.NamedTemporaryFile("w", suffix=".cmds", delete=False) as handle:
        handle.write("\n".join(commands) + "\n")
        name = handle.name
    try:
        env = dict(os.environ, E2FSPROGS_FAKE_TIME=FAKE_TIME)
        argv = ["debugfs"] + (["-w"] if write else []) + ["-f", name, image]
        done = subprocess.run(argv, capture_output=True, env=env)
    finally:
        os.unlink(name)
    if done.returncode != 0:
        raise EqError(f"debugfs failed on {image}: {done.stderr.decode(errors='replace')}")
    return done.stdout.decode("latin-1"), done.stderr.decode("latin-1")


def replay(host_tree, pristine, out):
    """Write the tree host Linux left onto a copy of the pristine image."""
    shutil.copyfile(pristine, out)
    commands = []
    seen = {}
    links = {}
    base = os.path.join(host_tree, ROOT)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        rel = os.path.relpath(dirpath, host_tree)
        commands.append(f"mkdir /{rel}")
        mode = stat.S_IMODE(os.lstat(dirpath).st_mode)
        commands.append(f"set_inode_field /{rel} mode 040{mode:03o}")
        for filename in sorted(filenames):
            path = os.path.join(dirpath, filename)
            info = os.lstat(path)
            target = f"/{rel}/{filename}"
            if not stat.S_ISREG(info.st_mode):
                raise EqError(f"host tree holds a non-regular file {path}")
            if info.st_ino in seen:
                commands.append(f"link {seen[info.st_ino]} {target}")
                links[seen[info.st_ino]] = info.st_nlink
                continue
            seen[info.st_ino] = target
            commands.append(f"write {path} {target}")
            commands.append(
                f"set_inode_field {target} mode 0100{stat.S_IMODE(info.st_mode):03o}")
    for target, count in links.items():
        commands.append(f"set_inode_field {target} links_count {count}")
    _out, err = debugfs(out, commands, write=True)
    bad = [line for line in err.splitlines()
           if line.strip() and not line.startswith("debugfs ")]
    if bad:
        raise EqError("debugfs replay reported: " + "; ".join(bad))


# ------------------------------------------------------- logical snapshot

LS_RE = re.compile(r"^/(\d+)/(\d+)/\d+/\d+/(.*)/(\d*)/$")


def listing(image, directories):
    """{dir: {name: (inode, mode, size)}} for each directory, one process."""
    out, _err = debugfs(image, [f'ls -p "{d}"' for d in directories])
    result = {}
    sections = re.split(r"^debugfs: ls -p .*$", out, flags=re.M)[1:]
    for directory, section in zip(directories, sections):
        entries = {}
        for line in section.splitlines():
            match = LS_RE.match(line.strip())
            if match:
                inode, mode, name, size = match.groups()
                if name not in (".", "..") and int(inode) != 0:
                    entries[name] = (int(inode), int(mode, 8), int(size or 0))
        result[directory] = entries
    return result


def walk(image, top):
    """Every directory under TOP (inclusive) with its entries."""
    tree = {}
    pending = [top]
    while pending:
        found = listing(image, pending)
        tree.update(found)
        pending = []
        for directory, entries in found.items():
            for name, (_inode, mode, _size) in entries.items():
                if stat.S_ISDIR(mode):
                    pending.append(directory.rstrip("/") + "/" + name)
    return tree


STAT_RE = re.compile(r"^Inode: (\d+) .*?Links: (\d+) .*?Blockcount: (\d+)$", re.S | re.M)


def inode_facts(image, inodes):
    """{inode: (links, i_blocks)} through one debugfs process."""
    inodes = sorted(set(inodes))
    out, _err = debugfs(image, [f"stat <{i}>" for i in inodes])
    facts = {}
    for section in re.split(r"^debugfs: stat ", out, flags=re.M)[1:]:
        number = re.search(r"^Inode: (\d+)", section, re.M)
        links = re.search(r"Links: (\d+)", section)
        blocks = re.search(r"Blockcount: (\d+)", section)
        if number and links and blocks:
            facts[int(number.group(1))] = (int(links.group(1)), int(blocks.group(1)))
    missing = set(inodes) - set(facts)
    if missing:
        raise EqError(f"{image}: no stat for inodes {sorted(missing)}")
    return facts


def contents(image, paths):
    with tempfile.TemporaryDirectory() as scratch:
        commands = []
        for index, path in enumerate(paths):
            commands.append(f'dump "{path}" {scratch}/{index}')
        debugfs(image, commands)
        result = {}
        for index, path in enumerate(paths):
            with open(f"{scratch}/{index}", "rb") as handle:
                result[path] = handle.read()
    return result


def snapshot(image):
    """{path: facts} under /ROOT, plus the whole-image counts."""
    full = walk(image, "/")
    eq = {d: e for d, e in full.items() if d == "/" + ROOT or d.startswith(f"/{ROOT}/")}
    inodes = {2}
    for entries in full.values():
        inodes.update(inode for inode, _mode, _size in entries.values())
    facts = inode_facts(image, inodes)
    files = {}
    regular = []
    for directory, entries in eq.items():
        files[directory] = ("dir", None, None, None, None, tuple(sorted(entries)))
        for name, (inode, mode, size) in entries.items():
            path = directory + "/" + name
            links, blocks = facts[inode]
            if stat.S_ISDIR(mode):
                continue
            files[path] = ("reg" if stat.S_ISREG(mode) else f"mode{mode:o}",
                           stat.S_IMODE(mode), size, links, blocks, None)
            if stat.S_ISREG(mode):
                regular.append(path)
    for directory in eq:
        if directory == "/" + ROOT:
            continue
        parent, name = directory.rsplit("/", 1)
        inode, mode, _size = full[parent][name]
        links, _blocks = facts[inode]
        kind = files[directory]
        files[directory] = (kind[0], stat.S_IMODE(mode), None, links, None, kind[5])
    data = contents(image, regular)
    files = {p: f + (data.get(p),) for p, f in files.items()}
    reachable_blocks = sum((blocks + 1) // 2 for _l, blocks in facts.values())
    return files, counts(image), reachable_blocks, len(facts)


def counts(image):
    done = subprocess.run(["dumpe2fs", image], capture_output=True, text=True)
    if done.returncode != 0:
        raise EqError(f"dumpe2fs failed on {image}")
    text = done.stdout
    sb_blocks = int(re.search(r"^Free blocks:\s+(\d+)$", text, re.M).group(1))
    sb_inodes = int(re.search(r"^Free inodes:\s+(\d+)$", text, re.M).group(1))
    gd_blocks = sum(int(m) for m in re.findall(r"^\s+(\d+) free blocks, ", text, re.M))
    gd_inodes = sum(int(m) for m in re.findall(r" free blocks, (\d+) free inodes", text, re.M))

    def ranges(label):
        total = 0
        for line in re.findall(rf"^\s+{label}: (.*)$", text, re.M):
            for part in filter(None, (p.strip() for p in line.split(","))):
                low, _, high = part.partition("-")
                total += int(high or low) - int(low) + 1
        return total
    return {"sb_blocks": sb_blocks, "sb_inodes": sb_inodes,
            "gd_blocks": gd_blocks, "gd_inodes": gd_inodes,
            "bitmap_blocks": ranges("Free blocks"),
            "bitmap_inodes": ranges("Free inodes")}


# -------------------------------------------------------------- verdicts

def split_log(log):
    """{row: [lines]} from a log."""
    rows = {}
    current = None
    for line in log.splitlines():
        if line.startswith("row "):
            current = line[4:]
            rows[current] = []
        elif line == "eq done":
            current = None
        elif current is not None:
            rows[current].append(line)
    return rows


def describe(fact):
    kind, mode, size, links, blocks, names, data = fact
    if kind == "dir":
        return f"dir mode={mode and oct(mode)} links={links} entries={len(names)}"
    shown = data[:24] if data is not None else None
    return (f"{kind} mode={oct(mode)} size={size} links={links} "
            f"i_blocks={blocks} data={shown!r}{'...' if data and len(data) > 24 else ''}")


def row_differences(name, kernel_files, host_files, kernel_log, host_log):
    prefix = f"/{ROOT}/{name}"
    diffs = []
    if kernel_log.get(name) != host_log.get(name):
        diffs.append(f"log: kernel {kernel_log.get(name)} host {host_log.get(name)}")
    paths = sorted(p for p in set(kernel_files) | set(host_files)
                   if p == prefix or p.startswith(prefix + "/"))
    for path in paths:
        k, h = kernel_files.get(path), host_files.get(path)
        if k != h:
            diffs.append(f"{path}: kernel {describe(k) if k else 'absent'}; "
                         f"host {describe(h) if h else 'absent'}")
    return diffs


def compare(rows, expected_log, kernel_image, host_image):
    kernel_files, kernel_counts, kernel_reach, kernel_inodes = snapshot(kernel_image)
    host_files, host_counts, host_reach, host_inodes = snapshot(host_image)
    log_bytes, _err = debugfs(kernel_image, [f"cat /{LOG}"])
    kernel_log = split_log(log_bytes)
    host_log = split_log(expected_log)
    if "eq done" not in log_bytes.splitlines():
        raise EqError(f"the kernel's /{LOG} does not end with 'eq done': "
                      f"the guest did not run the whole script ({log_bytes[-200:]!r})")
    failures = []
    table = []
    for name, expect, issue, _ops in rows:
        diffs = row_differences(name, kernel_files, host_files, kernel_log, host_log)
        outcome = "differ" if diffs else "match"
        table.append((name, issue, expect, outcome, diffs))
        if outcome != expect:
            failures.append(name)
    # whole-image rows
    for image, c in (("kernel", kernel_counts), ("host", host_counts)):
        if not (c["sb_blocks"] == c["gd_blocks"] == c["bitmap_blocks"] and
                c["sb_inodes"] == c["gd_inodes"] == c["bitmap_inodes"]):
            failures.append(f"counters({image})")
            table.append((f"counters({image})", "-", "match", "differ", [str(c)]))
    table.append(("counters", "-", "match", "match" if not any(
        f.startswith("counters") for f in failures) else "differ", []))
    kernel_sum = (kernel_counts["bitmap_blocks"] + kernel_reach,
                  kernel_counts["bitmap_inodes"] + kernel_inodes)
    host_sum = (host_counts["bitmap_blocks"] + host_reach,
                host_counts["bitmap_inodes"] + host_inodes)
    if kernel_sum != host_sum:
        failures.append("conservation")
        table.append(("conservation", "-", "match", "differ",
                      [f"free+reachable (blocks, inodes): kernel {kernel_sum} host {host_sum}"]))
    else:
        table.append(("conservation", "-", "match", "match", []))
    for name, issue, expect, outcome, diffs in table:
        verdict = "ok" if expect == outcome else "UNEXPECTED"
        print(f"ext2-eq row {name:<18} {issue:<6} expect={expect:<6} got={outcome:<6} {verdict}")
        for diff in diffs[:6]:
            print(f"    {diff}")
    if failures:
        raise EqError("rows with an unexpected outcome: " + ", ".join(failures) +
                      " (a fixed divergence flips its row in ops.eq to 'match')")
    report_pass("ext2-eq",
                f"{len(rows)} rows and 2 whole-image rows as recorded, "
                f"{len(kernel_files)} kernel paths compared",
                rows=len(rows), paths=len(kernel_files))


# ------------------------------------------------------------- self-test

def self_test():
    good = "row a match -\nmkdir a\nwrite a/f x\nrow b differ #1\nmkdir b\n"
    rows = parse(good)
    assert [r[0] for r in rows] == ["a", "b"], rows
    script = gen_sh(rows)
    assert "$B echo -n x >\"$R/a/f\"" in script, script
    for bad in ("mkdir a\n", "row a maybe -\n", "row a match -\nmkdir b\n",
                "row a match -\nwrite a/f 'x y'\n", "row a match -\nrow a match -\n",
                "row a match -\nfrob a\n"):
        try:
            parse(bad)
        except EqError:
            continue
        raise AssertionError(f"accepted {bad!r}")
    log = "row a\n1 mkdir a -> 0\n  a dir\nrow b\neq done\n"
    assert split_log(log) == {"a": ["1 mkdir a -> 0", "  a dir"], "b": []}
    files = {"/eq/a": ("dir", 0o755, None, 2, None, ("f",), None),
             "/eq/a/f": ("reg", 0o644, 1, 1, 2, None, b"x")}
    other = dict(files)
    other["/eq/a/f"] = ("reg", 0o644, 2, 1, 2, None, b"xy")
    assert row_differences("a", files, files, {}, {}) == []
    assert len(row_differences("a", files, other, {}, {})) == 1
    assert row_differences("b", files, other, {}, {}) == []
    report_pass("ext2-eq self-test", "parser, generator, log and row diff",
                cases=7)


def main(argv):
    try:
        if argv[1:] == ["self-test"]:
            self_test()
            return 0
        command, args = argv[1], argv[2:]
        rows = parse(open(args[0]).read())
        if command == "gen-sh" and len(args) == 2:
            with open(args[1], "w") as handle:
                handle.write(gen_sh(rows))
        elif command == "host" and len(args) == 3:
            log, _tree = run_host(rows, args[1], args[2])
            sys.stdout.write(log)
        elif command == "check-expected" and len(args) == 3:
            with tempfile.TemporaryDirectory() as work:
                log, _tree = run_host(rows, args[1], work)
            if open(args[2]).read() != log:
                raise EqError(f"{args[2]} is not what host Linux prints for {args[0]}; "
                              "regenerate it with 'ext2_eq.py host', never by hand")
            report_pass("ext2-eq host log", f"{args[2]} regenerated from host Linux",
                        lines=len(log.splitlines()))
        elif command == "replay" and len(args) == 4:
            with tempfile.TemporaryDirectory() as work:
                _log, tree = run_host(rows, args[1], work)
                replay(tree, args[2], args[3])
        elif command == "compare" and len(args) == 4:
            compare(rows, open(args[1]).read(), args[2], args[3])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except EqError as error:
        print(f"FAIL ext2-eq: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
