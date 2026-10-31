#!/usr/bin/env python3
"""Controls for layout_text and the layout-blind flag-guarded check (#1311).

layout_text must find an anchor across a moved newline or indent, still refuse
an absent or duplicate one, and not reach across a token boundary or a comment.
check_flag_guarded_fields.py must give one verdict however the same statements
are laid out, and still refuse a read the flag does not follow closely.
"""

from control_patch import ControlAnchorError, replace_once
from check_flag_guarded_fields import findings_for_text
from layout_text import LayoutSource, layout_count
from pass_line import CaseCount, report_pass

STRUCT = "struct R {\n    next: usize;\n    has_next: bool;\n}\n"


def guarded(body):
    return not findings_for_text("a.tkb", STRUCT + "fn f(r: R) {\n" + body + "\n}\n")


def main():
    cases = CaseCount()

    def expect(label, condition):
        cases.note()
        if not condition:
            raise SystemExit(f"FAIL layout-text controls: {label}")

    source = "// note\n    fn a(\n        b: u8) {\n\n  c = 1;\n}\nxc = 2;\n"
    expect("newline and indent moved", layout_count(source, "fn a(\n  b: u8) {") == 1)
    expect("blank line moved", replace_once(source, "b: u8) {\n  c = 1;", "z") ==
           "// note\n    fn a(\n        z\n}\nxc = 2;\n")
    expect("an indented anchor keeps a word start",
           layout_count(source, "      c = 1;") == 1 and layout_count(source, "      c = 2;") == 0)
    expect("the indent does not swallow the previous line",
           replace_once(source, "    c = 1;", "q").count("{\n\n") == 1)
    expect("spelling still counts", layout_count(source, "fn a (") == 0)
    cases.note()
    try:
        replace_once(source, "absent", "")
    except ControlAnchorError:
        pass
    else:
        raise SystemExit("FAIL layout-text controls: absent anchor accepted")
    cases.note()
    try:
        replace_once("a  b\na b\n", "a\nb", "")
    except ControlAnchorError:
        pass
    else:
        raise SystemExit("FAIL layout-text controls: duplicate anchor accepted")
    wrapped = LayoutSource(source)
    expect("LayoutSource in", "fn a(\n b: u8)" in wrapped and "nope" not in wrapped)
    expect("LayoutSource count", wrapped.count("fn a(\n b: u8)") == 1)

    read = "    let a = r.next;\n"
    flag = "    let b = r.has_next;\n"
    other = "    let c = 1;\n"
    expect("flag after the read", guarded(read + flag))
    expect("blank lines do not widen the distance", guarded(read + "\n\n\n" + flag))
    expect("two statements after", guarded(read + other + flag))
    expect("a flag three statements after is refused", not guarded(read + other + other + flag))
    expect("no flag is refused", not guarded(read))
    expect("a flag in a comment is no flag", not guarded(read + "    // r.has_next\n"))
    expect("flag first", guarded("    if (r.has_next) {\n" + read + "    }"))
    report_pass("layout-text controls",
                "anchors survive a relayout and are still refused when absent or doubled; "
                "flag-guarded verdicts ignore line breaks", cases=cases.ran)


if __name__ == "__main__":
    main()
