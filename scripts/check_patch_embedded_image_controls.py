#!/usr/bin/env python3
"""Exercise success and refusal paths of patch_embedded_image.py."""

from pathlib import Path
import subprocess
import sys
import tempfile

from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent
PATCHER = ROOT / "scripts/patch_embedded_image.py"


def run_case(directory: Path, binary: bytes, original: bytes,
             replacement: bytes) -> subprocess.CompletedProcess:
    paths = [directory / name for name in ("binary", "original", "replacement")]
    for path, content in zip(paths, (binary, original, replacement)):
        path.write_bytes(content)
    return subprocess.run(
        [sys.executable, str(PATCHER), *(str(path) for path in paths),
         str(directory / "output")],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    claims = 0
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        good = run_case(root, b"ELF-old-image-tail", b"old-image", b"new-image")
        if good.returncode != 0 or (root / "output").read_bytes() != b"ELF-new-image-tail":
            print("FAIL embedded-image-patch controls: valid replacement failed")
            return 1
        claims += 1
        for name, binary, original, replacement, diagnostic in (
            ("missing", b"ELF-tail", b"old", b"new", "found 0"),
            ("duplicate", b"old-middle-old", b"old", b"new", "found 2"),
            ("size", b"ELF-old-tail", b"old", b"long", "size differs"),
        ):
            case = root / name
            case.mkdir()
            result = run_case(case, binary, original, replacement)
            if result.returncode == 0 or diagnostic not in result.stderr:
                print(
                    "FAIL embedded-image-patch controls: "
                    f"{name} was not refused with its diagnostic"
                )
                return 1
            claims += 1
    report_pass(
        "embedded-image-patch controls",
        "one valid replacement succeeds; missing, duplicate and size-mismatched images are refused",
        claims=claims,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
