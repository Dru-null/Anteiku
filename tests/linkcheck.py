#!/usr/bin/env python3
"""Relative links and #anchors in Markdown files resolve.

usage: linkcheck.py <file.md>...   (paths from the repo root)

A link is [text](target) outside code. Targets with a scheme (https:,
mailto:) are not checked. A target must exist, relative to the file
that links it; an #anchor must match a heading of the .md it points at,
slugged the way GitHub does (lowercase, punctuation dropped, spaces to
hyphens, -1, -2 for repeats). Prints each bad link; exit 1 if any.
"""
import os
import re
import sys

FENCE = re.compile(r"^\s*(```|~~~)")
CODE_SPAN = re.compile(r"`[^`]*`")
LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")


def prose_lines(path):
    """Lines outside fenced code blocks."""
    in_code = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if FENCE.match(line):
                in_code = not in_code
                continue
            if not in_code:
                yield line


def slugs(path):
    out, seen = set(), {}
    for line in prose_lines(path):
        m = HEADING.match(line)
        if not m:
            continue
        t = m.group(2).replace("`", "").strip().lower()
        t = re.sub(r"[^\w\- ]", "", t).replace(" ", "-")
        n = seen.get(t, 0)
        seen[t] = n + 1
        out.add(t if n == 0 else "%s-%d" % (t, n))
    return out


def main(files):
    if not files:
        print("usage: linkcheck.py <file.md>...", file=sys.stderr)
        return 2
    bad = checked = 0
    cache = {}
    for f in files:
        for line in prose_lines(f):
            for target in LINK.findall(CODE_SPAN.sub("", line)):
                if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target):
                    continue
                checked += 1
                p, _, anchor = target.partition("#")
                dest = os.path.normpath(os.path.join(os.path.dirname(f), p)) if p else f
                if not os.path.exists(dest):
                    print("%s: no such file: %s" % (f, target))
                    bad += 1
                    continue
                if anchor and dest.endswith(".md"):
                    if dest not in cache:
                        cache[dest] = slugs(dest)
                    if anchor not in cache[dest]:
                        print("%s: no such heading: %s" % (f, target))
                        bad += 1
    print("%d links checked, %d bad" % (checked, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
