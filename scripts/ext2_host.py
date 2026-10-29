#!/usr/bin/env python3
"""ext2 equivalence, tier C (GitHub issue #1035): the kernel's ext2 driver
as a host process, against host Linux, over thousands of operations.

linux_user/ext2_host/ext2_host.exe is kernel/fs/ext2/ext2.tkb, its
mutation lock, the block layer and the syscalls' ext2 halves
(kernel/fs/ext2/ext2_syscall.tkb) compiled as the kernel compiles them,
over a RAM disk (ram_disk.tkb). This script drives it: an image on fd 3,
an operation script on stdin, one result line per operation (the program's
header comment is the protocol).

The oracle is host Linux, as for tier B (scripts/ext2_eq.py): every
operation is replayed with the same system calls on a scratch directory,
its errno is the expected one, and the tree host Linux leaves is written
with `debugfs -w` onto the pristine image (ext2_eq.replay). The two images
are compared logically (ext2_eq.snapshot: types, modes, sizes, link counts,
i_blocks, contents, names; counters; free+reachable conservation), and the
kernel's is checked with `e2fsck -fn` (tier A).

Where the two sides cannot agree by construction, the comparison says so
rather than skipping: host Linux's scratch directory does not run out of
space, so an ENOSPC from the kernel is accepted only when the kernel's own
free counts, when its failing write(2) or create was refused, were too low
for it (under ENOSPC_SLACK blocks,
or no free inode for a create), and the oracle then replays exactly the
bytes the kernel's successful write(2)s wrote (`written=`).

Modes:
  eq OPS            kernel/tests/ext2_eq/ops.eq, the QEMU lane's rows, with
                    each row's recorded match|differ outcome required
  campaign [--seeds N] [--ops L] [--every K] [--first S]
                    seeded random sequences; every K operations the kernel's
                    image is fsck'd and compared with the oracle's. A failure
                    prints the seed and the prefix length; `replay` reruns it
  replay SEED LEN   one campaign prefix, with its script and both results
  faults [--seeds N] [--ops L]
                    for every operation of a sequence and every write it
                    makes, that write fails (rejected, then torn): the
                    operation must fail and the image must be fsck-clean
                    and equal to the image before it (all or nothing)
  hostile [--images N]
                    seeded corruptions of a populated image, each mounted
                    and walked: every read ends, nothing stops the program
  control           a planted rollback bug (one staged block not freed) must
                    fail the campaign or, failing that, the fault run
  nearfull          a small write into a large file on a nearly full disk
                    succeeds (#1086)
  holes             writes past end of file leave holes, as on Linux (#1087)
  self-test         the parsers and the oracle, without the program

The default sizes are the linuxcheck member's; the long campaign is
`make ext2-host-long`.

Divergences the generator does not produce, each an open issue with its
tier-B row or a note there: #1021 (doubly indirect files; files stay
within 268 KiB), #1089 (a
torn write is outside the recovery model; `faults --torn` shows it), and
link(2), which the kernel does not implement. A rejected write may fence
the mount; the fault run then recovers it (ext2_recover, as the boot
fixture does) and compares the recovered image.
"""

import argparse
import errno
import os
import random
import re
import shutil
import stat
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ext2_eq  # noqa: E402
from pass_line import report_pass  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(REPO, "linux_user/ext2_host/ext2_host.exe")
IMAGE_LEN = 6291456          # KERNEL_EXT2_IMAGE_LEN, memory.tkb
FS_BLOCKS = 512              # small, so a campaign reaches ENOSPC
FS_INODES = 64
FAKE_TIME = ext2_eq.FAKE_TIME
ROOT = ext2_eq.ROOT          # every operation is under /eq
WRITE_CHUNK = 1024           # the kernel's write(2) limit (syscall.tkb)
MAX_FILE = (12 + 256) * 1024  # single indirect; #1021 beyond
ENOSPC_SLACK = 4             # blocks one write(2) or create can need
# Operations the fault run does not fail, each an open issue. None since
# #1088 and #1120 made O_TRUNC, unlink, rename and rmdir, create and mkdir
# all or nothing through the undo log.
FAULT_KNOWN = {}
FAULT_DENSE = 12             # every one of an operation's first writes
FAULT_LARGEST = 4000         # bytes per generated write in the fault run
STOP_STATUS = 86             # host_stubs.S's kernel_invariant_stop
TIMEOUT = 60

RESULT_RE = re.compile(
    r"^(\d+) (.*) -> (\S+)(?: written=(\d+))? free=(?:(\d+)/(\d+)|invalid)$")
MOUNT_RE = re.compile(r"^mounted free=(\d+)/(\d+)$")


class HostError(Exception):
    pass


def pattern_byte(offset, seed):
    """ext2_host.tkb's pattern_byte."""
    return (offset * 31 + (offset >> 8) + seed * 101 + 7) & 0xFF


def pattern(offset, length, seed):
    return bytes(pattern_byte(offset + i, seed) for i in range(length))


# --------------------------------------------------------------- images

def make_image(path, blocks=FS_BLOCKS, inodes=FS_INODES):
    """The fixture's mke2fs line (Makefile, KERNEL_EXT2_IMAGE), smaller, in
    a file of the extent the USB device exposes. /eq is made by the first
    operation of every run (run_program), as the tier-B script makes it."""
    with open(path, "wb") as handle:
        handle.truncate(IMAGE_LEN)
    env = dict(os.environ, E2FSPROGS_FAKE_TIME=FAKE_TIME)
    subprocess.run(["mke2fs", "-q", "-t", "ext2", "-b", "1024", "-I", "128",
                    "-N", str(inodes), "-O", "none", "-F",
                    "-U", "00000000-0000-0000-0000-000000001035",
                    "-E", "hash_seed=00000000-0000-0000-0000-000000001035",
                    path, str(blocks)],
                   check=True, env=env, capture_output=True)


def run_program(image, lines, exe=EXE):
    """Run the program on IMAGE (modified in place, `sync` appended);
    return (status, mount_free, results, stdout)."""
    script = f"mkdir {ROOT}\n" + "".join(line + "\n" for line in lines) + "sync\n"
    fd = os.open(image, os.O_RDWR)
    try:
        done = subprocess.run([exe], input=script.encode(), capture_output=True,
                              pass_fds=(fd,), timeout=TIMEOUT,
                              preexec_fn=lambda: os.dup2(fd, 3))
    finally:
        os.close(fd)
    out = done.stdout.decode("latin-1")
    results = []
    mount_free = None
    for line in out.splitlines():
        match = RESULT_RE.match(line)
        if match:
            number, text, err, written, blocks, inodes_free = match.groups()
            results.append({"line": int(number), "op": text, "errno": err,
                            "written": int(written) if written else None,
                            "free": (int(blocks), int(inodes_free)) if blocks else None})
            continue
        match = MOUNT_RE.match(line)
        if match:
            mount_free = (int(match.group(1)), int(match.group(2)))
    if results and results[0]["op"] == f"mkdir {ROOT}" and results[0]["errno"] == "0":
        mount_free = results[0]["free"]
        results = [dict(r, line=r["line"] - 1) for r in results[1:]]
    else:
        results = []
    return done.returncode, mount_free, results, out + done.stderr.decode("latin-1")


def fsck(image):
    done = subprocess.run(["e2fsck", "-fn", image], capture_output=True, text=True)
    return done.returncode, done.stdout


# --------------------------------------------------------------- oracle

def file_blocks(size):
    count = (size + 1023) // 1024
    return count + (1 if count > 12 else 0)


def size_of(path):
    return os.path.getsize(path) if os.path.exists(path) else 0


def write_need(path, offset, length, written):
    """The blocks the kernel claims for the failing write(2) of a pwrite:
    since #1086 only the blocks that write changes (ext2_block_replaced:
    the blocks it covers and the old partial last block when the file
    grows; a skipped block stays a hole, #1087), plus a new indirect block when the
    file needs one. Linux needs the new blocks only, so the difference is
    at most the copied blocks of one 1 KiB write(2) and the indirect."""
    size = os.path.getsize(path) if os.path.exists(path) else 0
    if written:
        size = max(size, offset + written)
    start = offset + written
    end = start + min(WRITE_CHUNK, length - written)
    old_count = (size + 1023) // 1024
    new_size = max(size, end)
    new_count = (new_size + 1023) // 1024
    need = 0
    for index in range(new_count):
        if (index * 1024 < end and start < index * 1024 + 1024) or \
                (index + 1 == old_count and new_size > size and size % 1024):
            need += 1
    return need + (1 if new_count > 12 else 0)


def linux_apply(tree, op, kernel=None, injected=False):
    """Apply one operation to TREE with host Linux's system calls; return
    the errno name.

    KERNEL, when given, is the kernel's result for the same operation. A
    failure there that is accepted -- an ENOSPC the free counts justify, or
    any failure when INJECTED (a write to the disk was failed on purpose)
    -- is replayed rather than compared: each system call is all or
    nothing, so the openat(2) is replayed when the kernel's succeeded
    (`written=` is printed) and so are exactly the bytes of the write(2)s
    that succeeded before the one that failed; nothing of the failing call
    is. The kernel's errno is returned for it."""
    words = op.split()
    name = words[0]
    path = lambda p: os.path.join(tree, p)  # noqa: E731
    failed = kernel is not None and kernel["errno"] != "0" and \
        (injected or kernel["errno"] == "ENOSPC")
    opened = failed and kernel["written"] is not None
    if failed and not injected:
        # the counts after the operation are the ones its failing write(2)
        # met: that write was rolled back, the earlier ones were kept
        blocks, inodes = kernel["free"]
        creates = name in ("mkdir", "trunc", "write", "pwrite", "seekwrite", "overwrite") and \
            not os.path.lexists(path(words[1]))
        need = ENOSPC_SLACK
        if name in ("pwrite", "seekwrite") and opened:
            offset, length = (int(w) for w in words[2:4])
            if name == "seekwrite":
                offset = min(offset, size_of(path(words[1])))
            need += write_need(path(words[1]), offset, length, kernel["written"])
        if not (blocks < need or (creates and inodes == 0)):
            return "ENOSPC unjustified: free %d blocks, %d inodes" % (blocks, inodes)
    if failed and not opened:
        return kernel["errno"]
    try:
        if name == "mkdir":
            os.mkdir(path(words[1]), 0o755)
        elif name == "rmdir":
            os.rmdir(path(words[1]))
        elif name == "unlink":
            os.unlink(path(words[1]))
        elif name == "rename":
            os.rename(path(words[1]), path(words[2]))
        elif name in ("trunc", "write"):
            fd = os.open(path(words[1]), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            try:
                if name == "write" and len(words) > 2 and not failed:
                    os.write(fd, words[2].encode())
            finally:
                os.close(fd)
        elif name in ("pwrite", "seekwrite"):
            offset, length, seed = (int(w) for w in words[2:5])
            if name == "seekwrite":
                offset = min(offset, size_of(path(words[1])))
            fd = os.open(path(words[1]), os.O_WRONLY | os.O_CREAT, 0o644)
            try:
                limit = kernel["written"] if failed else length
                done = 0
                while done < limit:
                    piece = min(WRITE_CHUNK, limit - done)
                    os.pwrite(fd, pattern(offset + done, piece, seed), offset + done)
                    done += piece
            finally:
                os.close(fd)
        elif name == "overwrite":
            with open(path(words[2]), "rb") as source:
                data = source.read()
            fd = os.open(path(words[1]), os.O_WRONLY | os.O_CREAT, 0o644)
            try:
                limit = kernel["written"] if failed else len(data)
                os.pwrite(fd, data[:limit], 0)
            finally:
                os.close(fd)
        else:
            raise HostError(f"unknown operation {op!r}")
    except OSError as error:
        return errno.errorcode.get(error.errno, str(error.errno))
    return kernel["errno"] if failed else "0"


def oracle_image(tree, pristine, out):
    ext2_eq.replay(tree, pristine, out)


# --------------------------------------------------------------- compare

def image_facts(image):
    files, counts, reach, inodes = ext2_eq.snapshot(image)
    return files, counts, (counts["bitmap_blocks"] + reach,
                           counts["bitmap_inodes"] + inodes)


def counters_agree(counts):
    return (counts["sb_blocks"] == counts["gd_blocks"] == counts["bitmap_blocks"] and
            counts["sb_inodes"] == counts["gd_inodes"] == counts["bitmap_inodes"])


def image_differences(kernel_image, other_image, prefix=f"/{ROOT}"):
    """What differs between two images under PREFIX, plus the whole-image
    rows; [] when they agree."""
    kfiles, kcounts, ksum = image_facts(kernel_image)
    ofiles, ocounts, osum = image_facts(other_image)
    diffs = []
    for path in sorted(set(kfiles) | set(ofiles)):
        if not (path == prefix or path.startswith(prefix + "/")):
            continue
        k, o = kfiles.get(path), ofiles.get(path)
        if k != o:
            diffs.append(f"{path}: kernel {ext2_eq.describe(k) if k else 'absent'}; "
                         f"other {ext2_eq.describe(o) if o else 'absent'}")
    if not counters_agree(kcounts):
        diffs.append(f"counters: kernel {kcounts}")
    if ksum != osum:
        diffs.append(f"conservation (free+reachable blocks, inodes): kernel {ksum} other {osum}")
    return diffs


def compare_run(pristine, lines, work, exe=EXE, fault=None):
    """Run LINES on the kernel and on host Linux; return the problems.
    FAULT, as (index, armed line), arms a disk-write fault before
    operation INDEX; that operation's failure is then accepted and
    replayed (linux_apply's INJECTED)."""
    kernel = os.path.join(work, "kernel.img")
    shutil.copyfile(pristine, kernel)
    program = list(lines)
    if fault is not None:
        program.insert(fault[0], fault[1])
    status, mount_free, results, out = run_program(kernel, program, exe)
    injected = re.search(r"^fault injected=1( fenced recover=(\w+))?$", out, re.M) \
        if fault is not None else None
    if fault is not None and not injected:
        return None, results       # the operation made fewer writes
    problems = []
    if injected and injected.group(1) and injected.group(2) != "ok":
        problems.append(f"fenced, and ext2_recover answered {injected.group(2)}")
    if status != 0:
        problems.append(f"program status {status}" +
                        (" (kernel_invariant_stop)" if status == STOP_STATUS else "") +
                        f"; tail: {out[-300:]!r}")
        return problems, results
    if len(results) != len(lines):
        problems.append(f"{len(results)} results for {len(lines)} operations")
        return problems, results
    tree = os.path.join(work, "tree")
    shutil.rmtree(tree, ignore_errors=True)
    os.mkdir(tree)
    os.mkdir(os.path.join(tree, ROOT))
    os.chmod(os.path.join(tree, ROOT), 0o755)
    free = mount_free
    old = os.umask(0o022)
    try:
        for index, (line, result) in enumerate(zip(lines, results), 1):
            injected = fault is not None and index - 1 == fault[0]
            expect = linux_apply(tree, line, result, injected)
            if expect != result["errno"]:
                problems.append(f"op {index} `{line}`: kernel {result['errno']} linux {expect}")
            free = result["free"]
    finally:
        os.umask(old)
    code, report = fsck(kernel)
    if code != 0:
        problems.append("e2fsck -fn: " + " | ".join(
            l for l in report.splitlines() if l and not l.startswith(("Pass ", "e2fsck ")))[:600])
    oracle = os.path.join(work, "oracle.img")
    oracle_image(tree, pristine, oracle)
    problems += image_differences(kernel, oracle)
    return problems, results


# --------------------------------------------------------------- eq rows

def eq_lines(rows):
    """ops.eq's rows as program operations, each row's span recorded."""
    lines = []
    spans = []
    skipped = []
    for name, _expect, _issue, ops in rows:
        first = len(lines)
        for _lineno, op, args in ops:
            p = [f"{ROOT}/{a}" for a in args]
            if op in ("mkdir", "rmdir", "unlink"):
                lines.append(f"{op} {p[0]}")
            elif op == "rename":
                lines.append(f"rename {p[0]} {p[1]}")
            elif op == "write":
                lines.append(f"write {p[0]} {args[1]}")
            elif op == "fill":
                # dd of=P bs=1024 count=N: O_TRUNC, then N one-KiB writes
                lines.append(f"trunc {p[0]}")
                lines.append(f"pwrite {p[0]} 0 {int(args[1]) * 1024} 1")
            elif op == "overwrite":
                lines.append(f"overwrite {p[0]} {p[1]}")
            elif op == "truncate":
                # truncate -s 0: open(O_CREAT) and ftruncate(2) to 0, the
                # same filesystem calls as O_TRUNC's (#1022)
                lines.append(f"trunc {p[0]}")
            elif op == "peer":
                # what the row tests is the descriptor (#1023): a position
                # kept across another open's truncate, which is syscall.tkb's
                # and not run here. The row's file is then absent on both
                # sides, and the row reports so.
                skipped.append(name)
            elif op == "adopt":
                # mv of the doubly-indirect fixture (#1021): run_eq plants
                # the same sparse file on the pristine image and in the
                # Linux tree, so the row's O_TRUNC releases the same tree
                lines.append(f"rename {ext2_eq.DIND_FIXTURE} {p[0]}")
            elif op == "files":
                for i in range(int(args[1])):
                    lines.append(f"trunc {p[0]}/{ext2_eq.LONG}{i}")
            else:
                raise HostError(f"ops.eq operation {op} has no host form")
        spans.append((first, len(lines)))
    return lines, spans, skipped


def run_eq(ops_path):
    rows = ext2_eq.parse(open(ops_path).read())
    lines, spans, skipped = eq_lines(rows)
    with tempfile.TemporaryDirectory(prefix="ext2_host_eq.") as work:
        pristine = os.path.join(work, "pristine.img")
        # the fixture's size: the rows were written against its free space
        make_image(pristine, blocks=6144, inodes=1024)
        if ext2_eq.adopted(rows):
            plant_fixture(pristine, work)
        problems, results = compare_run_rows(pristine, lines, spans, rows, work)
    if problems:
        raise HostError("ops.eq rows: " + "; ".join(problems))
    report_pass("ext2-host eq", f"{len(rows)} ops.eq rows as the QEMU lane records them, "
                f"{len(lines)} operations through the kernel's ext2 on the host"
                + (f" (descriptor-only operations not run: rows {', '.join(skipped)})"
                   if skipped else ""),
                rows=len(rows), operations=len(lines))


def plant_fixture(image, work):
    """The comparing QEMU runner's /lib/ext2-eq-dind, planted the same way."""
    source = os.path.join(work, "ext2-eq-dind")
    ext2_eq.write_fixture(source)
    directory = os.path.dirname(ext2_eq.DIND_FIXTURE)
    ext2_eq.debugfs(image, [f"mkdir /{directory}",
                            f"write {source} /{ext2_eq.DIND_FIXTURE}"], write=True)


def compare_run_rows(pristine, lines, spans, rows, work):
    kernel = os.path.join(work, "kernel.img")
    shutil.copyfile(pristine, kernel)
    status, free, results, out = run_program(kernel, lines)
    if status != 0 or len(results) != len(lines):
        return [f"program status {status}, {len(results)} results: {out[-300:]!r}"], results
    tree = os.path.join(work, "tree")
    os.mkdir(tree)
    os.mkdir(os.path.join(tree, ROOT))
    os.chmod(os.path.join(tree, ROOT), 0o755)
    if ext2_eq.adopted(rows):
        os.makedirs(os.path.join(tree, os.path.dirname(ext2_eq.DIND_FIXTURE)))
        ext2_eq.write_fixture(os.path.join(tree, ext2_eq.DIND_FIXTURE))
    klog, hlog = {}, {}
    old = os.umask(0o022)
    try:
        for (name, _e, _i, _ops), (first, last) in zip(rows, spans):
            klog[name], hlog[name] = [], []
            for index in range(first, last):
                expect = linux_apply(tree, lines[index], results[index])
                free = results[index]["free"]
                klog[name].append(f"{lines[index]} -> {results[index]['errno']}")
                hlog[name].append(f"{lines[index]} -> {expect}")
    finally:
        os.umask(old)
    oracle = os.path.join(work, "oracle.img")
    oracle_image(tree, pristine, oracle)
    kfiles, kcounts, ksum = image_facts(kernel)
    hfiles, _hcounts, hsum = image_facts(oracle)
    problems = []
    for name, expect, issue, _ops in rows:
        diffs = ext2_eq.row_differences(name, kfiles, hfiles, klog, hlog)
        outcome = "differ" if diffs else "match"
        verdict = "ok" if outcome == expect else "UNEXPECTED"
        print(f"ext2-host row {name:<18} {issue:<6} expect={expect:<6} got={outcome:<6} {verdict}")
        for diff in diffs[:4]:
            print(f"    {diff[:200]}")
        if outcome != expect:
            problems.append(f"row {name} {outcome}, recorded {expect}")
    if not counters_agree(kcounts):
        problems.append(f"counters {kcounts}")
    # Conservation is not a row here: a differ row leaves the two trees
    # different by design.
    return problems, results


# --------------------------------------------------------------- campaign

def name_for(rng):
    return rng.choice("abcdefgh") + str(rng.randrange(20))


class Model:
    """What the generator believes the tree holds. ENOSPC can only leave a
    file shorter or absent than believed, never longer."""

    def __init__(self):
        self.dirs = {ROOT}
        self.files = {}

    def children(self, d):
        prefix = d + "/"
        return [p for p in list(self.dirs) + list(self.files)
                if p.startswith(prefix) and "/" not in p[len(prefix):]]


def generate(seed, count, largest=80000):
    """COUNT operations from SEED."""
    rng = random.Random(seed)
    model = Model()
    lines = []
    while len(lines) < count:
        dirs = sorted(model.dirs)
        files = sorted(model.files)
        parent = rng.choice(dirs)
        fresh = f"{parent}/{name_for(rng)}"
        kind = rng.choices(
            ["mkdir", "write", "pwrite", "trunc", "unlink", "rmdir", "rename_file",
             "rename_dir", "error"],
            [8, 10, 30, 4, 10, 6, 8, 3, 3])[0]
        if kind == "mkdir":
            if fresh.count("/") > 5 or fresh in model.files:
                continue
            lines.append(f"mkdir {fresh}")
            model.dirs.add(fresh)
        elif kind == "write":
            target = rng.choice(files + [fresh]) if files else fresh
            if target in model.dirs:
                continue
            text = "".join(rng.choice("xyz0123456789") for _ in range(rng.randrange(1, 40)))
            lines.append(f"write {target} {text}")
            model.files[target] = len(text)
        elif kind == "pwrite":
            target = rng.choice(files + [fresh]) if files and rng.random() < 0.7 else fresh
            if target in model.dirs:
                continue
            size = model.files.get(target, 0)
            # a bias toward filling the image: one write in four is large
            length = rng.choice([rng.randrange(1, 64), rng.randrange(1, 3000),
                                 rng.randrange(1, 20000), rng.randrange(20000, 80000)])
            length = min(length, largest)
            # one write in five lands past EOF and leaves a hole (#1087);
            # the others are seekwrites, which never pass EOF
            if rng.random() < 0.2:
                offset = size + rng.choice([rng.randrange(1, 1024),
                                            rng.randrange(1024, 40000)])
                if offset + length > MAX_FILE:
                    continue
                lines.append(f"pwrite {target} {offset} {length} {rng.randrange(256)}")
                model.files[target] = max(size, offset + length)
                continue
            offset = rng.choice([0, size, rng.randrange(0, size + 1)])
            if offset + length > MAX_FILE:
                continue
            lines.append(f"seekwrite {target} {offset} {length} {rng.randrange(256)}")
            model.files[target] = max(size, offset + length)
        elif kind == "trunc":
            if not files:
                continue
            target = rng.choice(files)
            lines.append(f"trunc {target}")
            model.files[target] = 0
        elif kind == "unlink":
            if not files:
                continue
            target = rng.choice(files)
            lines.append(f"unlink {target}")
            del model.files[target]
        elif kind == "rmdir":
            candidates = [d for d in dirs if d != ROOT]
            if not candidates:
                continue
            target = rng.choice(candidates)
            lines.append(f"rmdir {target}")
            if not model.children(target):
                model.dirs.discard(target)
        elif kind == "rename_file":
            if not files:
                continue
            source = rng.choice(files)
            target = rng.choice(files + [fresh])
            if target in model.dirs or target == source:
                continue
            lines.append(f"rename {source} {target}")
            model.files[target] = model.files.pop(source)
        elif kind == "rename_dir":
            candidates = [d for d in dirs if d != ROOT and not model.children(d)]
            if not candidates:
                continue
            source = rng.choice(candidates)
            # within its own parent: the kernel does not move a directory
            target = source.rsplit("/", 1)[0] + "/" + name_for(rng)
            if target in model.dirs or target in model.files:
                continue
            lines.append(f"rename {source} {target}")
            model.dirs.discard(source)
            model.dirs.add(target)
        elif kind == "error":
            # the errnos at the leaf: EEXIST, ENOENT, EISDIR, ENOTDIR, ENOTEMPTY
            choice = rng.randrange(5)
            if choice == 0 and len(dirs) > 1:
                lines.append(f"mkdir {rng.choice(dirs[1:])}")
            elif choice == 1:
                lines.append(f"unlink {parent}/zz{rng.randrange(9)}")
            elif choice == 2 and len(dirs) > 1:
                lines.append(f"unlink {rng.choice(dirs[1:])}")
            elif choice == 3 and files:
                lines.append(f"rmdir {rng.choice(files)}")
            elif choice == 4:
                lines.append(f"rmdir {parent}/zz{rng.randrange(9)}")
    return lines


def campaign(seeds, ops, every, first=0, exe=EXE, quiet=False):
    """Return the first failure as (seed, prefix, problems), or None."""
    checks = 0
    with tempfile.TemporaryDirectory(prefix="ext2_host_campaign.") as work:
        pristine = os.path.join(work, "pristine.img")
        make_image(pristine)
        for seed in range(first, first + seeds):
            lines = generate(seed, ops)
            for prefix in list(range(every, ops, every)) + [ops]:
                problems, _results = compare_run(pristine, lines[:prefix], work, exe)
                checks += 1
                if problems:
                    return (seed, prefix, problems), checks
            if not quiet:
                print(f"ext2-host campaign seed {seed}: {ops} operations, "
                      f"{len(range(every, ops, every)) + 1} checkpoints agree")
    return None, checks


def report_failure(failure):
    seed, prefix, problems = failure
    print(f"FAIL ext2-host campaign: seed {seed}, prefix {prefix} "
          f"(rerun: scripts/ext2_host.py replay {seed} {prefix})", file=sys.stderr)
    for problem in problems[:12]:
        print(f"    {problem}", file=sys.stderr)


# --------------------------------------------------------------- faults

def run_faults(seeds, ops, first=0, exe=EXE, modes=("reject",)):
    """For every operation of each sequence and every disk write it makes
    (all of the first FAULT_DENSE, then at doubling distances), that write
    fails (rejected; torn too with --torn). Each system call must be all or nothing:
    the image must be fsck-clean and equal to host Linux's after the calls
    that succeeded (compare_run with a fault)."""
    checked = 0
    failures = []
    with tempfile.TemporaryDirectory(prefix="ext2_host_faults.") as work:
        pristine = os.path.join(work, "pristine.img")
        make_image(pristine)
        for seed in range(first, first + seeds):
            # small files: a fault run fails every write an operation makes,
            # so a large one makes thousands of disk writes to fail
            lines = generate(seed, ops, largest=FAULT_LARGEST)
            for index in range(len(lines)):
                if lines[index].split()[0] in FAULT_KNOWN:
                    continue
                for mode in modes:
                    k = 0
                    while True:
                        fault = (index, f"fault {k} {mode}")
                        problems, results = compare_run(pristine, lines[:index + 1], work,
                                                        exe, fault)
                        if problems is None:
                            break
                        checked += 1
                        if problems:
                            failures.append(f"seed {seed} op {index + 1} `{lines[index]}` "
                                            f"{fault[1]}: " + "; ".join(problems[:3]))
                            if len(failures) >= 10:
                                return checked, failures
                        k = k + 1 if k < FAULT_DENSE else k * 2
    return checked, failures


# --------------------------------------------------------------- hostile

HOSTILE_POPULATE = ["mkdir eq/d", "mkdir eq/d/e", "write eq/a hello",
                    "pwrite eq/b 0 20000 3", "pwrite eq/d/c 0 3000 4",
                    "write eq/d/e/f deep", "mkdir eq/g"]


def run_hostile(images, first=0):
    """Corrupt a populated image's metadata at seeded places and walk it."""
    walked = 0
    refused = 0
    failures = []
    with tempfile.TemporaryDirectory(prefix="ext2_host_hostile.") as work:
        base = os.path.join(work, "base.img")
        make_image(base)
        status, _f, results, out = run_program(base, HOSTILE_POPULATE)
        if status != 0 or any(r["errno"] != "0" for r in results):
            raise HostError(f"populating the hostile base failed: {out[-300:]!r}")
        data = bytearray(open(base, "rb").read())
        # the metadata a reader trusts: superblock, group descriptor, the
        # bitmaps, the inode table, and the first directory and indirect
        # blocks (the ones the base's files use)
        regions = [(1024, 1024), (2048, 1024), (3 * 1024, 2 * 1024),
                   (5 * 1024, 24 * 1024), (29 * 1024, 64 * 1024)]
        hostile = os.path.join(work, "hostile.img")
        for index in range(first, first + images):
            rng = random.Random(index)
            mutated = bytearray(data)
            for _ in range(rng.choice([1, 2, 4, 16])):
                start, length = rng.choice(regions)
                at = start + rng.randrange(length)
                mutated[at] = rng.choice([0, 0xFF, rng.randrange(256),
                                          mutated[at] ^ (1 << rng.randrange(8))])
            with open(hostile, "wb") as handle:
                handle.write(mutated)
            status, mount_free, _results, out = run_program(hostile, ["walk"])
            tag = f"image {index}"
            if status == 3 and "mount invalid" in out:
                refused += 1
                continue
            if status != 0:
                failures.append(f"{tag}: status {status}" +
                                (" (kernel_invariant_stop)" if status == STOP_STATUS else "") +
                                f" {out[-200:]!r}")
                continue
            if not re.search(r"^walk dirs=\d+ ", out, re.M):
                failures.append(f"{tag}: the walk did not finish: {out[-200:]!r}")
                continue
            walked += 1
    return walked, refused, failures


# --------------------------------------------------------------- control

PLANT_FROM = """    for index: usize in 0..<EXT2_MAX_WRITE_ALLOCATIONS {
        if (index < allocations.count) {
            let block: usize = ext2_write_allocations_block(slot, allocations,
                    index);
            if (block == 0 || block >= mount.filesystem_blocks) {
                settled = false;"""
PLANT_TO = PLANT_FROM.replace("if (index < allocations.count) {",
                              "if (index + 1 < allocations.count) {", 1)


def build_mutant(work):
    """ext2_host.exe with ext2_write_allocations_rollback forgetting the last
    staged block, built from a copy of the tree's .tkb sources."""
    root = os.path.join(work, "tree")
    for top in ("kernel", "linux_user"):
        for dirpath, _dirs, files in os.walk(os.path.join(REPO, top)):
            for name in files:
                if name.endswith((".tkb", ".S")):
                    source = os.path.join(dirpath, name)
                    target = os.path.join(root, os.path.relpath(source, REPO))
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copyfile(source, target)
    ext2 = os.path.join(root, "kernel/fs/ext2/ext2.tkb")
    text = open(ext2).read()
    if text.count(PLANT_FROM) != 1:
        raise HostError("the planted rollback bug no longer applies to ext2.tkb: "
                        "update PLANT_FROM to the rollback's first loop")
    open(ext2, "w").write(text.replace(PLANT_FROM, PLANT_TO))
    obj = os.path.join(work, "mutant.o")
    exe = os.path.join(work, "mutant.exe")
    takibi = os.path.join(REPO, "_build/default/bin/main.exe")
    subprocess.run([takibi, "linux_user/common_linux/uart.tkb",
                    "linux_user/common_linux/print.tkb",
                    "kernel/lib/execution_model.tkb",
                    "linux_user/ext2_host/host_support.tkb",
                    "linux_user/ext2_host/ram_disk.tkb",
                    "linux_user/ext2_host/ext2_host.tkb",
                    "--target", "x86_64-pc-linux-gnu", "-o", obj, "--forbid-trap"],
                   cwd=root, check=True, capture_output=True)
    stubs = os.path.join(work, "stubs.o")
    subprocess.run(["llvm-mc-19", "--triple=x86_64-pc-linux-gnu", "--filetype=obj",
                    os.path.join(REPO, "linux_user/ext2_host/host_stubs.S"), "-o", stubs],
                   check=True)
    build = os.path.join(REPO, "linux_user/build")
    subprocess.run(["ld.lld-19", "-static", "-nostdlib", "-e", "_start", obj,
                    os.path.join(build, "startup.o"), os.path.join(build, "syscall.o"),
                    stubs, "-o", exe], check=True)
    return exe


def run_control(seeds, ops, every):
    """The planted rollback bug must fail the campaign or the fault run.
    Since #1036 a write(2) claims its blocks one at a time, so ENOSPC alone
    seldom reaches the rollback; a rejected disk write does."""
    with tempfile.TemporaryDirectory(prefix="ext2_host_control.") as work:
        exe = build_mutant(work)
        failure, checks = campaign(seeds, ops, every, exe=exe, quiet=True)
        if failure is None:
            faulted, failures = run_faults(1, 40, exe=exe)
            checks += faulted
            if failures:
                failure = (0, "fault run", failures)
    if failure is None:
        raise HostError(f"the planted rollback bug passed {checks} checks: "
                        "neither the campaign nor the fault run reaches the "
                        "rollback, or sees a leaked block")
    seed, prefix, problems = failure
    report_pass("ext2-host control",
                f"a rollback that forgets one block fails seed {seed} at {prefix}: "
                f"{problems[0][:120]}", checks=checks)


# --------------------------------------------------------------- self-test

def run_nearfull():
    """GitHub issue #1086: on a nearly full disk, a small write(2) into a
    large file and an append to it succeed, as on Linux. Before the fix
    every write(2) copied the whole file to new blocks first, so both
    answered ENOSPC with far more blocks free than Linux needs."""
    with tempfile.TemporaryDirectory(prefix="ext2_host_nearfull.") as work:
        pristine = os.path.join(work, "pristine.img")
        make_image(pristine)
        probe = os.path.join(work, "probe.img")
        shutil.copyfile(pristine, probe)
        _, free, _, out = run_program(probe, [])
        if free is None:
            raise HostError("no mount line: " + out[-300:])
        # fillers, then a 200-block file (and its indirect block) that
        # leaves 8 blocks free: less than the file, more than a write needs
        size = 200 * 1024
        spare = free[0] - 8 - 201
        lines = []
        while spare > 0:
            blocks = min(spare, 12) if spare <= 13 else min(spare - 1, 256)
            spare -= blocks + (1 if blocks > 12 else 0)
            lines.append(f"pwrite {ROOT}/fill{len(lines)} 0 {blocks * 1024} 9")
        fillers = len(lines)
        lines += [f"pwrite {ROOT}/big 0 {size} 1",
                 f"pwrite {ROOT}/big 5000 10 2",
                 f"pwrite {ROOT}/big {size - 3000} 2000 3",
                 f"pwrite {ROOT}/big {size} 1500 4"]
        problems, results = compare_run(pristine, lines, work)
        for line, result in list(zip(lines, results))[fillers:]:
            if result["errno"] != "0":
                problems.append(f"`{line}` answered {result['errno']} with "
                                f"free={result['free']}")
        if problems:
            raise HostError("nearfull (#1086): " + "; ".join(problems))
    report_pass("ext2-host nearfull", f"a {size}-byte file with 8 blocks free takes "
                "an overwrite, a straddling write and an append (#1086)", cases=len(lines) - fillers)


def run_holes():
    """GitHub issue #1087: a write past end of file leaves the skipped
    blocks as holes, as on Linux -- same bytes and the same i_blocks --
    in the direct blocks and under the indirect block, and a later write
    into a hole fills just that block."""
    lines = [f"pwrite {ROOT}/s 5000 10 1",
             f"pwrite {ROOT}/s 40000 100 2",
             f"pwrite {ROOT}/s 1 3 3",
             f"pwrite {ROOT}/s 20000 1500 4",
             f"pwrite {ROOT}/t 200000 10 5",
             f"seekwrite {ROOT}/t 0 10 6"]
    with tempfile.TemporaryDirectory(prefix="ext2_host_holes.") as work:
        pristine = os.path.join(work, "pristine.img")
        make_image(pristine)
        problems, results = compare_run(pristine, lines, work)
        for line, result in zip(lines, results):
            if result["errno"] != "0":
                problems.append(f"`{line}` answered {result['errno']}")
        if problems:
            raise HostError("holes (#1087): " + "; ".join(problems))
    report_pass("ext2-host holes", "writes past end of file leave holes with "
                "Linux's bytes and i_blocks (#1087)", cases=len(lines))


def self_test():
    match = RESULT_RE.match("3 pwrite eq/a 0 10 1 -> ENOSPC written=4 free=2/9")
    assert match and match.group(3) == "ENOSPC" and match.group(4) == "4", match
    assert RESULT_RE.match("1 mkdir eq/a -> 0 free=700/90")
    assert pattern(0, 2, 0) == bytes([7, 38]), pattern(0, 2, 0)
    a, b = generate(5, 60), generate(5, 60)
    assert a == b and len(a) == 60, "the generator is not a function of its seed"
    for line in a:
        words = line.split()
        if words[0] == "seekwrite":
            assert int(words[2]) + int(words[3]) <= MAX_FILE, line
    with tempfile.TemporaryDirectory(prefix="ext2_host_selftest.") as tree:
        os.mkdir(os.path.join(tree, ROOT))
        assert linux_apply(tree, f"mkdir {ROOT}/d") == "0"
        assert linux_apply(tree, f"mkdir {ROOT}/d") == "EEXIST"
        assert linux_apply(tree, f"pwrite {ROOT}/d/f 5 3 1") == "0"
        assert open(os.path.join(tree, ROOT, "d/f"), "rb").read() == \
            b"\0" * 5 + pattern(5, 3, 1)
        assert linux_apply(tree, f"rmdir {ROOT}/d") == "ENOTEMPTY"
        kernel = {"errno": "ENOSPC", "written": 1024, "free": (900, 50)}
        assert linux_apply(tree, f"pwrite {ROOT}/h 0 4000 2",
                           {"errno": "ENOSPC", "written": None, "free": (0, 0)}) == "ENOSPC"
        assert not os.path.exists(os.path.join(tree, ROOT, "h"))
        assert linux_apply(tree, f"pwrite {ROOT}/g 0 4000 2", kernel) \
            .startswith("ENOSPC unjustified")
        kernel["free"] = (1, 50)
        assert linux_apply(tree, f"pwrite {ROOT}/g 0 4000 2", kernel) == "ENOSPC"
        assert os.path.getsize(os.path.join(tree, ROOT, "g")) == 1024
    rows = ext2_eq.parse("row r match -\nmkdir r\nfill r/f 2\nfiles r 2\n")
    lines, spans, skipped = eq_lines(rows)
    assert lines == [f"mkdir {ROOT}/r", f"trunc {ROOT}/r/f", f"pwrite {ROOT}/r/f 0 2048 1",
                     f"trunc {ROOT}/r/{ext2_eq.LONG}0", f"trunc {ROOT}/r/{ext2_eq.LONG}1"], lines
    assert spans == [(0, 5)]
    report_pass("ext2-host self-test", "result parser, pattern, generator, Linux oracle, "
                "ENOSPC justification and ops.eq translation", cases=7)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    p = sub.add_parser("eq")
    p.add_argument("ops")
    for name in ("campaign", "faults", "control"):
        p = sub.add_parser(name)
        p.add_argument("--seeds", type=int, default=6 if name != "faults" else 1)
        p.add_argument("--ops", type=int, default=150 if name != "faults" else 40)
        p.add_argument("--every", type=int, default=50)
        p.add_argument("--first", type=int, default=0)
        if name == "faults":
            p.add_argument("--torn", action="store_true",
                           help="also torn writes (#1089: outside the claimed model)")
    p = sub.add_parser("replay")
    p.add_argument("seed", type=int)
    p.add_argument("length", type=int)
    p = sub.add_parser("hostile")
    p.add_argument("--images", type=int, default=200)
    p.add_argument("--first", type=int, default=0)
    sub.add_parser("self-test")
    sub.add_parser("nearfull")
    sub.add_parser("holes")
    args = parser.parse_args(argv[1:])
    try:
        if args.mode == "self-test":
            self_test()
        elif args.mode == "nearfull":
            run_nearfull()
        elif args.mode == "holes":
            run_holes()
        elif args.mode == "eq":
            run_eq(args.ops)
        elif args.mode == "campaign":
            failure, checks = campaign(args.seeds, args.ops, args.every, args.first)
            if failure:
                report_failure(failure)
                return 1
            report_pass("ext2-host campaign",
                        f"{args.seeds} seeds x {args.ops} operations, {checks} checkpoints "
                        "fsck-clean and equal to host Linux", checkpoints=checks)
        elif args.mode == "replay":
            lines = generate(args.seed, args.length)
            with tempfile.TemporaryDirectory(prefix="ext2_host_replay.") as work:
                pristine = os.path.join(work, "pristine.img")
                make_image(pristine)
                problems, results = compare_run(pristine, lines, work)
            for line, result in list(zip(lines, results))[fillers:]:
                print(f"{line} -> {result['errno']} free={result['free']}")
            for problem in problems:
                print(f"PROBLEM {problem}")
            return 1 if problems else 0
        elif args.mode == "faults":
            checked, failures = run_faults(args.seeds, args.ops, args.first,
                                           modes=("reject", "torn") if args.torn else ("reject",))
            if failures:
                print("FAIL ext2-host faults:", file=sys.stderr)
                for failure in failures[:20]:
                    print(f"    {failure}", file=sys.stderr)
                return 1
            report_pass("ext2-host faults",
                        f"{checked} failed writes "
                        f"({'rejected and torn' if args.torn else 'rejected'}) across "
                        f"{args.seeds} x {args.ops} operations: each failed its "
                        "operation and left the image fsck-clean and as before "
                        "(after ext2_recover where it fenced)",
                        failed_writes=checked)
        elif args.mode == "hostile":
            walked, refused, failures = run_hostile(args.images, args.first)
            if failures:
                print("FAIL ext2-host hostile:", file=sys.stderr)
                for failure in failures[:20]:
                    print(f"    {failure}", file=sys.stderr)
                return 1
            report_pass("ext2-host hostile",
                        f"{args.images} corrupted images: {walked} walked to the end, "
                        f"{refused} refused at mount, none stopped",
                        walked=walked)
        elif args.mode == "control":
            run_control(args.seeds, args.ops, args.every)
    except (HostError, ext2_eq.EqError) as error:
        print(f"FAIL ext2-host: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
