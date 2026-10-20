#!/usr/bin/env python3
"""A console driver never types the marker it waits for (#856, #857).

WHY THIS EXISTS. A driver that types `echo MARKER` into a shell and waits for
MARKER on a line of its own can be answered by ash's echo of the command it
typed: peer-CPU workload lines can split that echo so a fragment -- MARKER
alone, or after a prompt -- lands on a line of its own before the command
ran. #856 saw it make the kernelsh-qemu httpd reap count read a ps that had
not run yet; #857 found the same shape in five more drivers.

THE RULE. In every scripts/*.py, a line typed to a console -- the bytes
argument of `os.write(fd, X)`, `write_line(uart, X)`, or `.send(X)`,
`.sendall(X)`, `.write(X)` -- is folded from its constants, names bound to
constants, and `typed_marker(...)` calls (scripts/typed_marker.py). Every
`echo WORD` in it must spell WORD with a shell quote (typed_marker inserts an
empty '' pair), or send its output away with `>`. A bare `echo` is allowed.
A WORD the fold cannot see (an f-string field, an attribute of another
module) is refused too: a reviewer cannot see it either.

WHAT IT IS NOT. It does not prove that what a driver waits for is echo's
output; it removes the one way the typed line could be mistaken for it.
Writes of str to files are out of scope: only bytes are typed to a console.
"""

import ast
import re
import sys
from pathlib import Path

from pass_line import report_pass
from typed_marker import typed_marker

ROOT = Path(__file__).resolve().parent.parent
OPAQUE = b"\x00"
TYPING_METHODS = {"send", "sendall", "write"}
ECHO = re.compile(rb"(?:^|[;&|\n(]|\s)echo\s+([^;&|\n>]*?)\s*(?=$|[;&|\n>])")


class Folder:
    """Fold a bytes expression from constants visible in one module."""

    def __init__(self, tree):
        self.bindings = {}
        for node in ast.walk(tree):
            if (isinstance(node, ast.Assign) and len(node.targets) == 1 and
                    isinstance(node.targets[0], ast.Name)):
                # A name bound twice to different values is not folded.
                name = node.targets[0].id
                if name in self.bindings and self.bindings[name] is not node.value:
                    self.bindings[name] = None
                else:
                    self.bindings[name] = node.value

    def fold(self, node, depth=0):
        if depth > 20:
            return OPAQUE
        if isinstance(node, ast.Constant):
            if isinstance(node.value, bytes):
                return node.value
            if isinstance(node.value, str):
                return node.value.encode("ascii", "replace")
            return OPAQUE
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return self.fold(node.left, depth + 1) + self.fold(node.right, depth + 1)
        if isinstance(node, ast.Name):
            bound = self.bindings.get(node.id)
            return OPAQUE if bound is None else self.fold(bound, depth + 1)
        if isinstance(node, ast.Call):
            func = node.func
            name = func.id if isinstance(func, ast.Name) else (
                func.attr if isinstance(func, ast.Attribute) else None)
            if name == "typed_marker" and len(node.args) == 1:
                inner = self.fold(node.args[0], depth + 1)
                return OPAQUE if OPAQUE in inner else typed_marker(inner)
            if name == "encode" and isinstance(func, ast.Attribute):
                return self.fold(func.value, depth + 1)
        return OPAQUE


def typed_arguments(tree):
    """Yield (line, expression) for every argument typed to a console."""
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not node.args:
            continue
        func = node.func
        if isinstance(func, ast.Attribute):
            if (func.attr == "write" and isinstance(func.value, ast.Name) and
                    func.value.id == "os" and len(node.args) == 2):
                yield node.lineno, node.args[1]
            elif func.attr in TYPING_METHODS and len(node.args) == 1:
                yield node.lineno, node.args[0]
        elif isinstance(func, ast.Name) and func.id == "write_line" and len(node.args) == 2:
            yield node.lineno, node.args[1]
    # A line typed a byte at a time (kernel_uart_wake_check.py) is the
    # iterable of a loop that types: `for i, b in enumerate(LINE): send(b)`.
    for node in ast.walk(tree):
        if not isinstance(node, ast.For):
            continue
        source = node.iter
        if (isinstance(source, ast.Call) and isinstance(source.func, ast.Name) and
                source.func.id == "enumerate" and source.args):
            source = source.args[0]
        body = ast.Module(body=node.body, type_ignores=[])
        if any(True for _ in _direct_typing_calls(body)):
            yield node.lineno, source


def _direct_typing_calls(tree):
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in TYPING_METHODS:
                yield node
            elif isinstance(func, ast.Name) and func.id == "write_line":
                yield node


def problems_in(source, label):
    tree = ast.parse(source)
    folder = Folder(tree)
    found = []
    typed = 0
    for line, expression in typed_arguments(tree):
        if not _is_bytes(expression, folder):
            continue
        typed += 1
        text = folder.fold(expression)
        for match in ECHO.finditer(text):
            word = match.group(1)
            if not word or b"'" in word or b'"' in word:
                continue
            if text[match.end():match.end() + 1] == b">":
                continue  # redirected: the output never reaches the console
            shown = word.replace(OPAQUE, b"<unseen>").decode("ascii", "replace")
            found.append(f"{label}:{line}: typed `echo {shown}` spells its "
                         "output marker unquoted; use typed_marker() "
                         "(scripts/typed_marker.py, #857)")
    return found, typed


def _is_bytes(expression, folder, depth=0):
    """Only bytes go to a console; a str argument is a file or log write."""
    if depth > 20:
        return False
    for node in ast.walk(expression):
        if isinstance(node, ast.Constant) and isinstance(node.value, bytes):
            return True
        if isinstance(node, ast.Attribute) and node.attr == "encode":
            return True
        if isinstance(node, ast.Name):
            bound = folder.bindings.get(node.id)
            if bound is not None and _is_bytes(bound, folder, depth + 1):
                return True
    return False


def main():
    files = sorted((ROOT / "scripts").glob("*.py"))
    problems = []
    typed = 0
    for path in files:
        source = path.read_text(encoding="ascii")
        # A file that never spells `echo` cannot type one; skip its parse.
        if "echo" not in source:
            continue
        found, count = problems_in(source, str(path.relative_to(ROOT)))
        problems += found
        typed += count
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    report_pass("typed-markers",
                f"{len(files)} scripts, {typed} typed console lines; no typed "
                "echo spells its output marker",
                files=len(files), typed=typed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
