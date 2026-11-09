#!/usr/bin/env python3
"""Faithful boot-attach, alias and handle-word controls for the maintained policy."""
import sys
import check_io_handle_boot_phase as policy
from pass_line import CaseCount, report_pass

CASES = CaseCount()
BASE = '''let mut regs: IoHandle(Regs);
fn setup(phase: borrow BootPhase[boot]) {
    io_handle_attach(&regs, window);
}
fn use_regs() { regs.status = regs.status | 1; }
'''


def main():
    failures=[]
    def case(name,text,accept):
        CASES.note()
        errors,_,_=policy.problems_in({'kernel/a.tkb':text})
        if (not errors)!=accept: failures.append(name+': '+repr(errors))
    errors,calls,handles=policy.problems_in(policy.source_files())
    CASES.note()
    if errors or not calls or not handles: failures.append('real maintained tree: '+repr(errors))
    case('borrowed phase and register operations',BASE,True)
    case('repeated in-phase attach',BASE.replace('    io_handle_attach(&regs, window);','    io_handle_attach(&regs, first);\n    io_handle_attach(&regs, second);'),True)
    case('body range and cast are not a return refinement',
         BASE.replace('    io_handle_attach(&regs, window);',
                      '    for i: usize in 0..<1 { let n: usize = i as usize; }\n'
                      '    io_handle_attach(&regs, window);'), True)
    case('refined return has its own header brace',
         BASE.replace('BootPhase[boot]) {',
                      'BootPhase[boot]) -> {0..<4 as usize} {'), True)
    case('one-line named functions', BASE.replace('\n', ' '), True)
    case('one-line missing phase', BASE.replace('phase: borrow BootPhase[boot]', '').replace('\n',' '), False)
    probe = ('let mut uart: IoHandle(Regs); fn boot(p: borrow BootPhase[&ended]) { '
             'for i: usize in 0..<1 { let n: usize = i as usize; } '
             'io_handle_attach(&uart, window); }')
    for text, expected in ((probe,1),(probe.replace('p: borrow BootPhase[&ended]',''),0)):
        CASES.note()
        issues, actual, _ = policy.problems_in({'kernel/review.tkb':text})
        if actual != expected or (expected and issues) or (
                not expected and not any('requires an enclosing borrowed BootPhase' in e for e in issues)):
            failures.append('exact coordinator body-range/cast probe: '+repr(issues))
    case('missing phase',BASE.replace('phase: borrow BootPhase[boot]',''),False)
    case('owned phase is not borrowed',BASE.replace('borrow BootPhase','BootPhase'),False)
    case('sink phase is not borrowed',BASE.replace('borrow BootPhase','sink BootPhase'),False)
    case('phase in comment is not authority',BASE.replace('phase: borrow BootPhase[boot]','/* phase: borrow BootPhase[boot] */'),False)
    case('inline private header',BASE.replace('fn setup','private inline fn setup'),True)
    case('relayout',BASE.replace('io_handle_attach(&regs, window)','io_handle_attach\n(\n &regs,\n window\n)'),True)
    case('function alias',BASE.replace('io_handle_attach(&regs, window);','let attach = io_handle_attach; attach(&regs, window);'),False)
    case('callback escape',BASE.replace('io_handle_attach(&regs, window);','save(io_handle_attach);'),False)
    case('nested callback cannot borrow outer phase',BASE.replace('io_handle_attach(&regs, window);','let callback = fn() { io_handle_attach(&regs, window); };'),False)
    case('unrelated callback does not reject attach',BASE.replace('io_handle_attach(&regs, window);','let callback = fn() { other(); }; io_handle_attach(&regs, window);'),True)
    case('bare copy',BASE+'fn copy() { let saved = regs; }',False)
    case('whole-word assignment',BASE+'fn copy() { regs = other; }',False)
    case('parenthesized assignment',BASE+'fn copy() { (regs) = other; }',False)
    case('whole-word address',BASE+'fn escape() { let pointer = &regs; }',False)
    case('erased token parameter',BASE+'fn quiet(c: sink Confirmation[&regs]) {}',True)
    case('erased token local',BASE+'fn quiet() { let mut c: Confirmation[&regs] = { 1 }; }',True)
    case('runtime array address',BASE+'fn escape() { let pointers = [&regs]; }',False)
    case('type index followed by runtime escape',BASE+'fn escape(c: sink Confirmation[&regs]) { save(&regs); }',False)

    case('generic write bypass',BASE+'fn escape() { replace(&regs, other); }',False)
    case('global initializer copy',BASE+'let mut other: IoHandle(Regs) = regs;',False)
    case('register-field address is not handle word',BASE+'fn field() { observe(&regs.status); }',True)
    case('member spelling is not global word',BASE+'fn field() { record.regs = 3; }',True)
    case('local shadow',BASE+'fn field() { let regs: usize = 0; other(regs); }',True)
    case('tuple shadow',BASE+'fn field() { let (regs, other) = pair; consume(regs); }',True)
    case('shadow initializer still reads global',BASE+'fn field() { let regs = regs; }',False)
    case('parameter shadow',BASE+'fn field(regs: usize) { consume(regs); }',True)
    case('hidden generated spelling',BASE.replace('IoHandle(Regs)','IoHandle__Regs'),False)
    case('unreviewed aggregate storage',BASE+'struct Box { device: IoHandle(Regs); }',False)
    case('literal is not code',BASE+'fn text() { emit("io_handle_attach &regs"); }',True)
    case('comment is not code',BASE+'// io_handle_attach(&regs, window)\n',True)
    for failure in failures: print('FAIL io-handle-boot-phase-controls: '+failure)
    if failures: return 1
    report_pass('io-handle-boot-phase-controls','maintained attaches and phase/copy/address/function-value controls retain the boundary',cases=CASES.ran)
    return 0

if __name__=='__main__': sys.exit(main())
