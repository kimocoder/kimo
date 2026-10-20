#!/usr/bin/env python3
"""Fail when a tracked file has a multi-byte UTF-8 character across an 8 KiB boundary.

The Codacy Analysis CLI reads every file it reports on through better-files'
UnicodeCharset, whose decoder treats a character split between two 8192-byte
reads as malformed input. The CLI then dies with MalformedInputException while
writing its SARIF, and the JVM stays up until the job times out. Moving the
character a few bytes either way (rewording the line) avoids it.
"""

from __future__ import annotations

import subprocess
import sys

BOUNDARY = 8192


def splits(data: bytes) -> list[int]:
    """Byte offsets of characters whose encoding crosses a BOUNDARY multiple."""
    found = []
    i = 0
    while i < len(data):
        lead = data[i]
        width = 1 if lead < 0x80 else 2 if lead >> 5 == 0b110 else 3 if lead >> 4 == 0b1110 else 4
        if width > 1 and (i // BOUNDARY) != ((i + width - 1) // BOUNDARY):
            found.append(i)
        i += width
    return found


def main() -> int:
    files = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.split(b"\0")
    bad = 0
    for name in filter(None, files):
        try:
            with open(name, "rb") as fh:
                data = fh.read()
        except (IsADirectoryError, FileNotFoundError):
            continue
        for offset in splits(data):
            line = data.count(b"\n", 0, offset) + 1
            print(f"{name.decode()}:{line}: multi-byte character at byte {offset} crosses an "
                  f"{BOUNDARY}-byte boundary (hangs the Codacy CLI); reword the line", file=sys.stderr)
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
