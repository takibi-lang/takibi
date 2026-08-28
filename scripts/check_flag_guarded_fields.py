#!/usr/bin/env python3
"""Refuse a read of a field that is only valid when its flag says so.

A struct in this kernel often carries a pair: an optional field `X` and a
boolean `has_X` that says whether `X` was ever written. `X` is assigned
only on the path that makes it meaningful -- linking a child, recording a
parent -- so on a record that never took that path it holds whatever the
pool slot's memory held. `has_X` is the only thing that makes it readable.

That is a convention, and conventions are kept by hand until they are not.
GitHub issue #464's neighbourhood had exactly one place that broke it:
`kernel_process_reap_zombie` read `parent.first_child` before asking
`has_first_child`, reachable only from the teardown sweep, which finds an
Exited record by scanning every slot and gets the record ITSELF back as
its own parent when `has_parent` is false. The walk that followed indexed
`record_at()` at a number nobody chose. Running this checker at that
commit reports it; running it one commit later does not.

WHAT COUNTS AS GUARDED

  * `has_X` is mentioned anywhere in the function before the read, or
  * `has_X` is mentioned within two lines after it.

The second is the read-then-decide shape this tree uses on purpose:

      let mut following = record_at(c).next_sibling;      // value copy
      let has_following = record_at(c).has_next_sibling;  // decides it

Copying an unset field into a local is harmless; only USING it is not, and
the flag arrives before any use. Accepting that shape is what keeps this
check at zero findings on a clean tree instead of three it cannot explain.

This is a lint over text, not a proof over a program. It does not follow
the flag into a helper, and a function that checks a DIFFERENT record's
flag satisfies it. It is cheap, it runs on every build, and it caught the
one real instance -- which is the bar it was written to meet.

  usage: check_flag_guarded_fields.py [ROOT ...]      default: kernel
"""

import re
import sys
import pathlib

READ_THEN_CHECK_LINES = 3


def struct_flag_pairs(text):
    """Field names X where some struct declares both `X` and `has_X`."""
    pairs = {}
    for match in re.finditer(r'struct\s+(\w+)\s*\{(.*?)\n\}', text, re.S):
        names = set(re.findall(r'^\s*(?:private\s+)?(\w+)\s*:',
                               match.group(2), re.M))
        for name in names:
            if name.startswith("has_") and name[4:] in names:
                pairs.setdefault(name[4:], set()).add(match.group(1))
    return pairs


def functions(text):
    """(name, first line index, body lines) for each `fn` in the file."""
    lines = text.split("\n")
    found, index = [], 0
    while index < len(lines):
        header = re.match(r'^\s*(private\s+)?fn\s+(\w+)', lines[index])
        if not header:
            index += 1
            continue
        depth, cursor, opened = 0, index, False
        while cursor < len(lines):
            depth += lines[cursor].count("{") - lines[cursor].count("}")
            if "{" in lines[cursor]:
                opened = True
            if opened and depth <= 0:
                break
            cursor += 1
        found.append((header.group(2), index, lines[index:cursor + 1]))
        index = cursor + 1
    return found


def findings_for(path):
    text = path.read_text()
    pairs = struct_flag_pairs(text)
    if not pairs:
        return []
    out = []
    for name, start, body in functions(text):
        for field in pairs:
            # A read is any mention that is not an assignment target and
            # not the flag itself. An assignment may end its line, which is
            # why `=` at end of line counts as one.
            read = re.compile(r'\.' + field + r'\b(?!\s*=(?:[^=]|$))')
            flag = re.compile(r'\bhas_' + field + r'\b')
            flag_read = re.compile(r'\.has_' + field + r'\b')
            first_read = next(
                (i for i, line in enumerate(body)
                 if read.search(line) and not flag_read.search(line)), None)
            if first_read is None:
                continue
            first_flag = next(
                (i for i, line in enumerate(body) if flag.search(line)), None)
            if first_flag is not None and first_flag <= first_read:
                continue
            if any(flag.search(line) for line in
                   body[first_read:first_read + READ_THEN_CHECK_LINES]):
                continue
            out.append((path, start + 1 + first_read, name, field))
    return out


def main(argv):
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path("kernel")]
    findings = []
    files = 0
    for root in roots:
        for path in sorted(root.rglob("*.tkb")):
            files += 1
            findings.extend(findings_for(path))
    for path, line, function, field in findings:
        print("  %s:%d: %s() reads .%s before asking has_%s"
              % (path, line, function, field, field))
    if findings:
        print("FAIL kernel/flag-guarded-fields: %d read(s) of a field whose "
              "paired flag was not consulted first" % len(findings))
        return 1
    print("PASS kernel/flag-guarded-fields: every optional field read under "
          "its has_ flag (%d files)" % files)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
