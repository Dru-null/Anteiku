#!/usr/bin/env python3
"""Relative links and #anchors in Markdown files resolve.

usage: linkcheck.py <file.md>...              (paths from the repo root)
       linkcheck.py --pointers <file>...      scripts, yaml: docs they name

A link is [text](target) outside code. Targets with a scheme (https:,
mailto:) are not checked. A target must exist, relative to the file
that links it; an #anchor must match a heading of the .md it points at,
slugged the way GitHub does (lowercase, punctuation dropped, spaces to
hyphens, -1, -2 for repeats). Prints each bad link; exit 1 if any.

--pointers reads any text file (comment lines joined, so a pointer may
wrap) for the docs it sends people to: docs/<x>.md, stacks/<x>.md and
README.md, with an optional #anchor; in stacks/*.yaml also a bare
<x>.md (that folder's guide). A heading named right after a path,
quoted (`docs/backups.md, "Your photos"`) or one capitalised word or two
(`stacks/arr.md, Traps`), must be a heading of that doc (the quoted one
exactly, the other as the start of one); so must a quoted heading the
text says is in the README. ports.md is setup.sh's output, never checked.
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


def headings(path):
    """Heading texts, lowercased, backticks dropped."""
    return [m.group(2).replace("`", "").strip().lower()
            for m in map(HEADING.match, prose_lines(path)) if m]


# A path starts a word, or follows printf's %s (a colour code before it).
PTR = re.compile(r"(?:(?<![\w./-])|(?<=%s))((?:docs|stacks)/[a-z0-9-]+\.md|README\.md)(#[a-z0-9-]+)?")
BARE = re.compile(r"(?<![\w./-])([a-z0-9-]+\.md)(#[a-z0-9-]+)?")
QUOTED = re.compile(r'\s*,\s*\\?"([^"\\]+)\\?"')
WORDS = re.compile(r"\s*,\s*([A-Z][a-z]*(?: [0-9A-Za-z]+)?)\b")
README_Q = re.compile(r'\\?"([^"\\]+)\\?"\s+in\s+the\s+README\b')
GENERATED = {"ports.md"}


def pointers(files):
    bad = checked = 0
    for f in files:
        with open(f, encoding="utf-8") as fh:
            text = re.sub(r"\n[ \t]*#+[ \t]*", " ", fh.read())
        # (doc, #anchor or None, heading named or None, exact?)
        found = []
        paths = [(m, m.group(1)) for m in PTR.finditer(text)]
        if f.startswith("stacks/") and f.endswith(".yaml"):
            paths += [(m, "stacks/" + m.group(1)) for m in BARE.finditer(text)
                      if m.group(1) not in GENERATED]
        for m, doc in paths:
            after = text[m.end():]
            q = QUOTED.match(after)
            w = None if q else WORDS.match(after)
            want = q.group(1) if q else (w.group(1) if w else None)
            found.append((doc, m.group(2), want, bool(q)))
        found += [("README.md", None, m.group(1), True) for m in README_Q.finditer(text)]
        for doc, anchor, want, exact in found:
            checked += 1
            if not os.path.exists(doc):
                print("%s: no such doc: %s" % (f, doc))
                bad += 1
                continue
            if anchor and anchor[1:] not in slugs(doc):
                print("%s: no such heading: %s%s" % (f, doc, anchor))
                bad += 1
                continue
            if want is None:
                continue
            hs = headings(doc)
            low = want.strip().lower()
            if not (low in hs if exact else any(h.startswith(low) for h in hs)):
                print('%s: %s has no heading "%s"' % (f, doc, want))
                bad += 1
    print("%d pointers checked, %d bad" % (checked, bad))
    return 1 if bad else 0


def main(files):
    if files[:1] == ["--pointers"]:
        if len(files) < 2:
            print("usage: linkcheck.py --pointers <file>...", file=sys.stderr)
            return 2
        return pointers(files[1:])
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
