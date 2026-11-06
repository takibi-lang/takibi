#!/usr/bin/env python3
"""GitHub issue #1377: every workflow `run:` script parses as bash.

The CI workflow wraps step scripts in `bash ... -c '<payload>'` so that
scripts/run_lane.sh can time them. An apostrophe in a comment inside such
a payload ("the runner image's") closes the single quote, and every CI
run failed with `unexpected EOF while looking for matching quote` -- a
failure no local lane sees, because no local lane runs the workflow.

For every `run: |` block in .github/workflows/*.yml this check:

  * runs `bash -n` on the block (GitHub Actions runs it with bash);
  * finds each single-quoted `-c '` payload (opened at a line end, closed
    by a line holding only `'`), refuses any apostrophe inside it -- an
    even number of them would still parse but split the payload silently
    -- and runs `bash -n` on the payload too.

Planted blocks with each defect are refused, so the check cannot pass by
matching nothing.
"""
import re
import subprocess
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
RUN_RE = re.compile(r"^(\s*)(?:-\s+)?run:\s*\|\s*$")
OPEN_RE = re.compile(r"\s-c\s+'\s*$")


def run_blocks(text: str) -> list[tuple[int, str]]:
    """(first line number, dedented script) for each `run: |` block."""
    lines = text.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        m = RUN_RE.match(lines[i])
        i += 1
        if not m:
            continue
        key_indent = len(m.group(1))
        start = i
        body = []
        while i < len(lines) and (not lines[i].strip()
                                  or len(lines[i]) - len(lines[i].lstrip()) > key_indent):
            body.append(lines[i])
            i += 1
        indents = [len(l) - len(l.lstrip()) for l in body if l.strip()]
        cut = min(indents) if indents else 0
        blocks.append((start + 1, "\n".join(l[cut:] for l in body) + "\n"))
    return blocks


def bash_n(script: str) -> str | None:
    r = subprocess.run(["bash", "-n"], input=script, text=True,
                       capture_output=True, timeout=5)
    return (r.stderr.strip() or "bash -n failed") if r.returncode else None


def block_problems(script: str) -> tuple[list[str], int]:
    out = []
    payloads = 0
    err = bash_n(script)
    if err:
        out.append(f"does not parse: {err}")
    lines = script.splitlines()
    i = 0
    while i < len(lines):
        if not OPEN_RE.search(lines[i]):
            i += 1
            continue
        payloads += 1
        j = i + 1
        while j < len(lines) and lines[j].strip() != "'":
            j += 1
        payload = lines[i + 1:j]
        for k, line in enumerate(payload):
            if "'" in line:
                out.append(f"payload line {k + 1} holds an apostrophe, which "
                           f"closes the single-quoted -c payload: {line.strip()}")
        err = bash_n("\n".join(payload) + "\n")
        if err:
            out.append(f"payload does not parse: {err}")
        i = j + 1
    return out, payloads


def main() -> int:
    workflows = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    failed = False
    nblocks = npayloads = 0
    for path in workflows:
        for line, script in run_blocks(path.read_text()):
            nblocks += 1
            found, n = block_problems(script)
            npayloads += n
            for item in found:
                failed = True
                print(f"FAIL workflow-shell: .github/workflows/{path.name}:"
                      f"{line} {item}", file=sys.stderr)
    if failed:
        return 1
    # Controls: the #1377 shape, an even apostrophe pair, and a plain
    # syntax error outside any payload.
    planted = {
        "odd apostrophe": "bash -c '\n  # the runner image's archive\n  true\n'\n",
        "apostrophe pair": "bash -c '\n  # it's the image's\n  true\n'\n",
        "syntax error": "if true; then\n  echo\n",
    }
    for name, script in planted.items():
        if not block_problems(script)[0]:
            print(f"FAIL workflow-shell: the planted {name} was not refused",
                  file=sys.stderr)
            return 1
    good = "bash -c '\n  # the runner image archive\n  echo \"ok\"\n'\n"
    if block_problems(good)[0]:
        print("FAIL workflow-shell: the planted good block was refused",
              file=sys.stderr)
        return 1
    yml = "    steps:\n      - name: x\n        run: |\n          echo a\n          echo b\n      - name: y\n"
    if run_blocks(yml) != [(4, "echo a\necho b\n")]:
        print("FAIL workflow-shell: the planted workflow was not extracted",
              file=sys.stderr)
        return 1
    report_pass("workflow-shell",
                f"{nblocks} run script(s) in {len(workflows)} workflow(s) "
                f"parse as bash, and {npayloads} single-quoted -c payload(s) "
                "hold no apostrophe; planted bad ones are refused",
                blocks=nblocks, payloads=npayloads)
    return 0


if __name__ == "__main__":
    sys.exit(main())
