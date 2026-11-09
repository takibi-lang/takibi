#!/usr/bin/env python3
"""Keep maintained IoHandle words behind the boot-phase attach boundary.

The language primitive stays general. In kernel/ and linux_user/, handle
storage is a direct global, used only by register projection or as the direct
first argument of io_handle_attach in a function borrowing BootPhase. Copies,
whole-word addresses and function-value aliases cannot bypass that boundary.
Comments/literals and local shadows are handled by the shared source scanner.
This repository check does not prove the trusted phase mint or CPU_ON ordering.
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_skeleton, function_header, per_file

ROOT = Path(__file__).resolve().parent.parent
TOKEN = re.compile(r'[A-Za-z_]\w*|\d+|=>|::|->|\.\.|[^\s]')
NAME = re.compile(r'^[A-Za-z_]\w*$')


@per_file
def scan(text):
    code = code_skeleton(text)
    tokens = tuple((m.group(), m.start(), m.end()) for m in TOKEN.finditer(code))
    words = [t[0] for t in tokens]
    positions = {t[1]: i for i, t in enumerate(tokens)}
    pairs, stack = {}, []
    for i, w in enumerate(words):
        if w in ('(', '[', '{'):
            stack.append(i)
        elif w in (')', ']', '}'):
            if stack and words[stack[-1]] == {')': '(', ']': '[', '}': '{'}[w]:
                a = stack.pop(); pairs[a] = i
    def body_after(end):
        i = end + 1
        refined_return = None
        if i < len(words) and words[i] == '->':
            r = i + 1
            while r < len(words) and words[r] in ('*', '&', 'mut', 'io'):
                r += 1
            if r < len(words) and words[r] == '{':
                refined_return = r
        while i < len(words):
            if words[i] in (';', '='):
                return None
            if words[i] in ('(', '['):
                i = pairs.get(i, len(words)) + 1; continue
            if words[i] == '{':
                close = pairs.get(i)
                if close is None: return None
                if words[i-1] == '!' or i == refined_return:
                    i = close + 1; continue
                return i, close
            i += 1
        return None
    functions = []
    named_open = set()
    header = function_header(suffix=r'\s*\(')
    for token, word in enumerate(words):
        if word != 'fn' or token + 2 >= len(tokens):
            continue
        start = tokens[token][1]
        m = header.match(code[start:tokens[token+2][2]])
        if m is None:
            continue
        opening = positions.get(start + m.end()-1)
        if opening is None or opening not in pairs: continue
        named_open.add(opening)
        end = pairs[opening]; body = body_after(end)
        if body:
            params = words[opening+1:end]
            phase = any(params[j:j+3] == ['borrow', 'BootPhase', '['] for j in range(len(params)))
            functions.append((body[0], body[1], phase, opening, end))
    # An outer phase never licenses a nested anonymous callback.
    for i, w in enumerate(words[:-1]):
        if w != 'fn' or words[i+1] != '(' or i+1 in named_open: continue
        if not any(a < i < b for a,b,_,_,_ in functions): continue
        end = pairs.get(i+1); body = body_after(end) if end is not None else None
        if body:
            params = words[i+2:end]
            phase = any(params[j:j+3] == ['borrow','BootPhase','['] for j in range(len(params)))
            functions.append((body[0],body[1],phase,i+1,end))
    declarations, handles, bindings, shadows = [], [], set(), []
    for i,w in enumerate(words):
        if w != 'let': continue
        j = i+1
        if j < len(words) and words[j] == 'mut': j += 1
        if j >= len(words): continue
        if words[j] == '(' and j in pairs:
            names = [(k,words[k]) for k in range(j+1,pairs[j]) if NAME.match(words[k])]
        elif NAME.match(words[j]):
            names = [(j,words[j])]
        else: continue
        bindings.update(k for k,_ in names)
        semi = next((k for k in range(j,len(words)) if words[k] == ';'),len(words))
        top = not any(words[a] == '{' and a < i < b for a,b in pairs.items())
        if top and len(names)==1 and words[j+1:j+4] == [':','IoHandle','(']:
            type_end = next((k for k in range(j,semi) if words[k] == "="),semi)
            declarations.append((i,type_end)); handles.append(names[0][1])
        if not top:
            scope = min((b for a,b in pairs.items() if words[a]=='{' and a<i<b),default=len(words))
            shadows.extend((n,semi+1,scope) for _,n in names)
    for a,b,_,p,q in functions:
        for j in range(p+1,q-1):
            if NAME.match(words[j]) and words[j+1] == ':':
                bindings.add(j); shadows.append((words[j],a,b))
    return tokens, tuple(functions), tuple(declarations), tuple(handles), frozenset(bindings), tuple(shadows)


@per_file
def mask(text):
    return code_skeleton(text)


def problems_in(files):
    names = set()
    for text in files.values():
        names.update(re.findall(r"\blet\s+(?:mut\s+)?(\w+)\s*:\s*IoHandle\s*\(", mask(text)))
    mention = re.compile(r"\b(?:io_handle_attach|IoHandle|IoHandle__\w*" +
                         "".join("|" + re.escape(n) for n in sorted(names)) + r")\b")
    parsed = {p: scan(t) for p,t in files.items() if mention.search(mask(t))}
    handles = {h for data in parsed.values() for h in data[3]}
    problems = []
    calls = 0
    for path,(tokens,functions,decls,_,bindings,shadows) in parsed.items():
        words = [t[0] for t in tokens]
        def error(i,message):
            line = files[path].count('\n',0,tokens[i][1])+1
            problems.append(f'{path}:{line}: {message}')
        for i,w in enumerate(words):
            declaration = any(a <= i <= b for a,b in decls)
            if w.startswith('IoHandle__') or (w=='IoHandle' and not declaration):
                error(i,'IoHandle storage must use a direct global declaration')
            if w == 'io_handle_attach':
                owner = min((f for f in functions if f[0]<i<f[1]),key=lambda f:f[1]-f[0],default=None)
                if i+1>=len(words) or words[i+1]!='(':
                    error(i,'io_handle_attach cannot escape as a function value')
                elif owner is None or not owner[2]:
                    error(i,'io_handle_attach requires an enclosing borrowed BootPhase')
                else: calls += 1
            if w not in handles or declaration or i in bindings: continue
            if i and words[i-1]=='.': continue
            if any(n==w and a<=i<=b for n,a,b in shadows): continue
            if i+1<len(words) and words[i+1]=='.': continue
            # An erased static index in a type annotation does not read or
            # address the runtime handle word. The compiler checks its type.
            if i >= 4 and words[i-2:i] == ['[', '&'] and words[i+1:i+2] == [']']:
                t = i - 3
                if t >= 1 and NAME.match(words[t]):
                    before = t - 1
                    if words[before] == 'sink': before -= 1
                    if before >= 0 and words[before] == ':': continue
            if i>=3 and words[i-3:i]==['io_handle_attach','(','&'] and i+1<len(words) and words[i+1]==',': continue
            error(i,f'{w}: handle word may only be attached directly or projected to a register')
    return problems, calls, len(handles)


def source_files():
    return {str(p.relative_to(ROOT)):p.read_text() for tree in ('kernel','linux_user')
            for p in (ROOT/tree).rglob('*.tkb') if not {'build','_build'} & set(p.relative_to(ROOT).parts)}


def main():
    problems,calls,handles=problems_in(source_files())
    for problem in problems: print('ERROR io-handle-boot-phase: '+problem)
    if problems: return 1
    if not calls or not handles:
        print('FAIL io-handle-boot-phase: empty boundary'); return 1
    report_pass('io-handle-boot-phase',f'{calls} attaches borrow BootPhase; {handles} handle words cannot be copied or addressed outside attach',claims=calls+handles)
    return 0

if __name__=='__main__':
    sys.exit(main())
