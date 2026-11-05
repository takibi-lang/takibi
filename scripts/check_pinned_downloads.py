#!/usr/bin/env python3
"""GitHub issues #1355 and #1358: every download the build makes is pinned.

Alpine keeps only a branch's latest package revision, so a pinned
revision's URL can 404 one day, or a URL can start serving other bytes.
Nothing noticed until a clean build failed. This check refuses:

  * a `curl` recipe line in the Makefile outside `define fetch_pinned`,
    the one fetch that verifies a sha256 before a rule can use the file;
  * a `*_URL` variable with no `*_SHA256` partner of 64 hex digits.

In scripts/*.sh (#1358) it refuses:

  * a `name=https://...` assignment with no `<stem>sha` / `<stem>SHA256`
    partner of 64 hex digits (`toolchain_url` pairs with `toolchain_sha`,
    `TLA_URL` with `TLA_SHA256`, `url` with `sha`);
  * a curl or wget command that names a URL literally, or fetches through
    a variable that is neither a pinned URL nor a function parameter
    (`local url=$1`) of a script that checks sha256sum. A command with
    `--noproxy` talks to the board on the test LAN, not the internet.

Planted inputs with one of each are refused too, so the check cannot pass
by matching nothing.
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent

URL_RE = re.compile(r"^([A-Z0-9_]+)_URL\s*:?=\s*\S", re.M)
SHA_RE = re.compile(r"^([A-Z0-9_]+)_SHA256\s*:?=\s*([0-9a-f]{64})\s*$", re.M)


def problems(text: str) -> list[str]:
    found: list[str] = []
    in_macro = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("define fetch_pinned"):
            in_macro = True
            continue
        if in_macro and line.startswith("endef"):
            in_macro = False
            continue
        if not in_macro and line.startswith("\t") and re.search(r"\bcurl\b", line):
            found.append(f"line {number}: curl outside fetch_pinned")
    pinned = {match.group(1) for match in SHA_RE.finditer(text)}
    for match in URL_RE.finditer(text):
        if match.group(1) not in pinned:
            found.append(f"{match.group(1)}_URL has no {match.group(1)}_SHA256")
    return found


SH_URL_RE = re.compile(r"^\s*(?:local\s+)?([A-Za-z0-9_]*?)(url|URL)=[\"']?https?://", re.M)
SH_SHA_RE = re.compile(r"^\s*(?:local\s+)?([A-Za-z0-9_]*?)(sha|SHA256)=[\"']?([0-9a-f]{64})[\"']?\s*$", re.M)
SH_PARAM_RE = re.compile(r"\blocal\s+([^;\n]*)")
SH_FETCH_RE = re.compile(r"(?:^|[\s;|&($`])(curl|wget)\s+-")


def sh_commands(text: str):
    """Yield (line number, command) with backslash continuations joined."""
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        start = index
        command = lines[index]
        while command.endswith("\\") and index + 1 < len(lines):
            index += 1
            command = command[:-1] + " " + lines[index]
        index += 1
        yield start + 1, command


def sh_problems(text: str) -> list[str]:
    found: list[str] = []
    pins = {(m.group(1), m.group(2)) for m in SH_SHA_RE.finditer(text)}
    urls: set[str] = set()
    for m in SH_URL_RE.finditer(text):
        stem, kind = m.group(1), m.group(2)
        name = stem + kind
        urls.add(name)
        if (stem, "sha" if kind == "url" else "SHA256") not in pins:
            found.append(f"{name} has no {stem}{'sha' if kind == 'url' else 'SHA256'} of 64 hex digits")
    params: set[str] = set()
    if "sha256sum" in text:
        for m in SH_PARAM_RE.finditer(text):
            for part in m.group(1).split():
                name, _, value = part.partition("=")
                if re.fullmatch(r"\$[1-9]", value):
                    params.add(name)
    for number, command in sh_commands(text):
        stripped = command.lstrip()
        if stripped.startswith("#") or not SH_FETCH_RE.search(command):
            continue
        if "--noproxy" in command:
            continue
        if re.search(r"https?://", command):
            found.append(f"line {number}: curl/wget names a URL literally")
            continue
        names = set(re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", command))
        if not names & (urls | params):
            found.append(f"line {number}: curl/wget fetches no pinned URL")
    return found


def main() -> int:
    text = (ROOT / "Makefile").read_text()
    found = problems(text)
    if found:
        for item in found:
            print(f"FAIL pinned-downloads: Makefile {item}", file=sys.stderr)
        return 1
    scripts = sorted((ROOT / "scripts").glob("*.sh"))
    sh_found = 0
    sh_urls = 0
    for path in scripts:
        script = path.read_text()
        sh_urls += len(SH_URL_RE.findall(script))
        for item in sh_problems(script):
            sh_found += 1
            print(f"FAIL pinned-downloads: scripts/{path.name} {item}", file=sys.stderr)
    if sh_found:
        return 1
    planted_sh = ("a_url=https://example.invalid/a.tgz\n"
                  "curl -o a.tgz \"$a_url\"\n"
                  "curl -fsSL \\\n  -o b https://example.invalid/b\n"
                  "curl -o c \"$other\"\n")
    if len(sh_problems(planted_sh)) != 3:
        print("FAIL pinned-downloads: the planted script was not refused", file=sys.stderr)
        return 1
    good_sh = ("a_url=https://example.invalid/a.tgz\n"
               "a_sha=" + "0" * 64 + "\n"
               "curl -o a.tgz \"$a_url\"\n"
               "curl --noproxy '*' --output x http://board/\n")
    if sh_problems(good_sh):
        print("FAIL pinned-downloads: the planted pinned script was refused", file=sys.stderr)
        return 1
    planted = "X_URL := https://example.invalid/x.apk\n$(X):\n\tcurl -o $@ $(X_URL)\n"
    if len(problems(planted)) != 2:
        print("FAIL pinned-downloads: the planted control was not refused", file=sys.stderr)
        return 1
    report_pass("pinned-downloads",
                f"{len(URL_RE.findall(text))} downloaded package(s), each "
                "fetched through fetch_pinned with a sha256, and "
                f"{sh_urls} in {len(scripts)} scripts/*.sh, each with a "
                "sha256 partner; planted unpinned ones are refused",
                packages=len(URL_RE.findall(text)),
                script_urls=sh_urls,
                pins=len(SHA_RE.findall(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
