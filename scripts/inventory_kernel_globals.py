#!/usr/bin/env python3
"""Index explicit kernel globals and lexical accesses; this is not alias analysis."""

import argparse
import bisect
import csv
import hashlib
import io
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9]*|[^\s]')
FIELDS = ['file', 'source_sha256', 'line', 'name', 'binding', 'visibility', 'type',
          'initializer', 'main_targets', 'access_sites', 'direct_store_sites',
          'address_sites', 'external_sites']


def tokens(source):
    return [(m.group(), m.start()) for m in TOKEN.finditer(source)
            if not m.group().startswith(('//', '/*', '"'))]


def source_index(path):
    source = (ROOT / path).read_text()
    ts = tokens(source)
    lines = [i for i, char in enumerate(source) if char == '\n']
    declarations, references = [], []
    depth, parens, brackets, function, pending_fn = 0, 0, 0, '-', None
    i = 0
    while i < len(ts):
        word, offset = ts[i]
        line = bisect.bisect_left(lines, offset) + 1
        if depth == 0 and parens == 0 and brackets == 0 and word == 'fn':
            pending_fn = ts[i + 1][0]
        if depth == 0 and parens == 0 and brackets == 0 and word == 'let':
            start = i
            mutable = ts[i + 1][0] == 'mut'
            name_i = i + 2 if mutable else i + 1
            name = ts[name_i][0]
            if ts[name_i + 1][0] != ':':
                raise ValueError(f'{path}:{line}: untyped top-level declaration')
            end = name_i + 2
            nesting = 0
            type_end = None
            while end < len(ts):
                value = ts[end][0]
                if nesting == 0 and value == '=' and type_end is None:
                    type_end = end
                if nesting == 0 and value == ';':
                    break
                if value in ('[', '(', '{'):
                    nesting += 1
                elif value in (']', ')', '}'):
                    nesting -= 1
                end += 1
            if end == len(ts):
                raise ValueError(f'{path}:{line}: unterminated declaration')
            boundary = ts[type_end if type_end is not None else end][1]
            spelling = source[ts[name_i + 2][1]:boundary]
            spelling = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', '', spelling)
            initializer = '-' if type_end is None else ' '.join(
                source[ts[type_end][1] + 1:ts[end][1]].split())
            declarations.append(dict(file=path, source_sha256=hashlib.sha256(source.encode()).hexdigest(),
                                     line=str(line), name=name, initializer=initializer,
                                     binding='mutable' if mutable else 'immutable',
                                     visibility='private' if start and ts[start - 1][0] == 'private' else 'public',
                                     type=' '.join(spelling.split())))
            i = end + 1
            continue
        if word == '{':
            if depth == 0:
                header_brace = pending_fn and (parens or brackets or
                    (i and ts[i - 1][0] in ('!', '>')))
                if not header_brace:
                    function = pending_fn or '-'
                    pending_fn = None
            depth += 1
        elif word == '}':
            depth -= 1
            if depth == 0:
                function = '-'
        elif word == '(':
            parens += 1
        elif word == ')':
            parens -= 1
        elif word == '[':
            brackets += 1
        elif word == ']':
            brackets -= 1
        elif re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', word):
            next_i = i + 1
            while next_i < len(ts):
                if ts[next_i][0] == '.':
                    next_i += 2
                elif ts[next_i][0] == '[':
                    level = 1
                    next_i += 1
                    while next_i < len(ts) and level:
                        level += (ts[next_i][0] == '[') - (ts[next_i][0] == ']')
                        next_i += 1
                else:
                    break
            store = next_i < len(ts) and ts[next_i][0] == '=' and (
                next_i + 1 == len(ts) or ts[next_i + 1][0] != '=')
            references.append((word, f'{path}:{line}@{function}',
                               i > 0 and ts[i - 1][0] == '&', store))
        i += 1
    return declarations, references


def render():
    tracked = subprocess.check_output(['git', 'ls-files', '-z', 'kernel'], cwd=ROOT).decode().split('\0')
    paths = sorted(p for p in tracked if p.endswith('.tkb'))
    declarations, references = [], []
    for path in paths:
        ds, rs = source_index(path)
        declarations.extend(ds)
        references.extend(rs)
    if not declarations:
        raise ValueError('no explicit kernel global declarations found')
    main = {}
    for target in ('qemu', 'rpi5'):
        depfile = ROOT / f'kernel/build/{target}/main.o.d'
        if not depfile.exists():
            raise ValueError(f'missing {depfile}; run make kernelbuild first')
        main[target] = set(re.findall(r'kernel/[A-Za-z_0-9/.-]+\.tkb', depfile.read_text()))
    by_name = {}
    for name, site, address, store in references:
        by_name.setdefault(name, []).append((site, address, store))
    out = io.StringIO()
    writer = csv.DictWriter(out, FIELDS, delimiter='\t', lineterminator='\n')
    writer.writeheader()
    for row in sorted(declarations, key=lambda r: (r['file'], int(r['line']))):
        sites = by_name.get(row['name'], [])
        # Private symbols belong to one file. Public-name hits remain lexical:
        # alternative platform definitions, field names and shadowing may collide.
        if row['visibility'] == 'private':
            sites = [(s, a, w) for s, a, w in sites if s.startswith(row['file'] + ':')]
        row['main_targets'] = ','.join(t for t in main if row['file'] in main[t]) or 'outside-main'
        row['access_sites'] = ';'.join(dict.fromkeys(s for s, _, _ in sites)) or '-'
        row['direct_store_sites'] = ';'.join(dict.fromkeys(s for s, _, w in sites if w)) or '-'
        row['address_sites'] = ';'.join(dict.fromkeys(s for s, a, _ in sites if a)) or '-'
        row['external_sites'] = ';'.join(dict.fromkeys(s for s, _, _ in sites
                                       if not s.startswith(row['file'] + ':'))) or '-'
        writer.writerow(row)
    return out.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', type=Path, help='compare an existing TSV with the current index')
    parser.add_argument('--dispositions', type=Path, help='verify complete authored disposition coverage')
    args = parser.parse_args()
    try:
        result = render()
        if args.dispositions:
            indexed = list(csv.DictReader(io.StringIO(result), delimiter='\t'))
            reviewed = list(csv.DictReader(io.StringIO(args.dispositions.read_text()), delimiter='\t'))
            keys = [(r['file'], r['name']) for r in reviewed]
            expected = {(r['file'], r['name']) for r in indexed}
            required = ('family', 'owner', 'access_contract', 'disposition', 'rationale')
            if len(keys) != len(set(keys)) or set(keys) != expected:
                raise ValueError('disposition coverage has missing, duplicate or extra declarations')
            if any(not row.get(key, '').strip() for row in reviewed for key in required):
                raise ValueError('each disposition needs owner, access contract and rationale')
        if args.check:
            if args.check.read_text() != result:
                raise ValueError(f'{args.check}: differs from current source/access index')
            print(f'Current global/access index matches: {len(result.splitlines()) - 1} declarations')
        else:
            sys.stdout.write(result)
    except (ValueError, OSError, KeyError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
