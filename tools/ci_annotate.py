#!/usr/bin/env python3
"""Turn xcodebuild compiler errors and test failures into GitHub Actions annotations.

Annotations show up on the run page and through the public check-runs API, so
failures can be read without downloading the full log.
Set ANNOTATE_OFFSET=10, 20, ... in further steps to see more.
Usage: python3 tools/ci_annotate.py build/logs/build.log [more logs...]
"""
import os
import re
import sys

ROOT = os.environ.get("GITHUB_WORKSPACE", os.getcwd()).rstrip("/") + "/"
DIAG = re.compile(r"^(?P<file>/[^:]+\.swift):(?P<line>\d+):(?P<col>\d+): (?P<kind>error|warning): (?P<msg>.*)$")
SWIFT_TESTING = re.compile(r"✘ Test (?P<name>.+?) recorded an issue at (?P<file>[\w./-]+\.swift):(?P<line>\d+):\d+: (?P<msg>.*)")
PAGE = 10  # GitHub keeps at most 10 error annotations per step
OFFSET = int(os.environ.get("ANNOTATE_OFFSET", "0"))


def esc(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(paths) -> None:
    seen = set()
    errors = []
    for path in paths:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n")
                m = DIAG.match(line)
                if m and m["kind"] == "error":
                    rel = m["file"].replace(ROOT, "")
                    key = (rel, m["line"], m["msg"])
                    if key not in seen:
                        seen.add(key)
                        errors.append((rel, m["line"], m["col"], m["msg"]))
                    continue
                t = SWIFT_TESTING.search(line)
                if t:
                    key = (t["file"], t["line"], t["msg"])
                    if key not in seen:
                        seen.add(key)
                        errors.append((f"MyMoneyAI/Tests/{os.path.basename(t['file'])}", t["line"], "1",
                                       f"{t['name']}: {t['msg']}"))
    if not errors:
        # Fallback: errors without file:line:col (linker, build system, crashes).
        for path in paths:
            if not os.path.exists(path):
                continue
            with open(path, encoding="utf-8", errors="replace") as f:
                for raw in f:
                    line = raw.strip()
                    if re.search(r"\berror\b[:]|\bfatal\b|Undefined symbol|failed with a nonzero exit code", line, re.I):
                        key = ("", "", line)
                        if key not in seen:
                            seen.add(key)
                            errors.append((os.path.basename(path), "1", "1", line[:900]))
    for rel, line, col, msg in errors[OFFSET:OFFSET + PAGE]:
        print(f"::error file={rel},line={line},col={col}::{esc(msg)}")
    print(f"{len(errors)} unique error(s) found")


if __name__ == "__main__":
    main(sys.argv[1:])
