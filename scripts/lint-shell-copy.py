#!/usr/bin/env python3
"""shell-copy-literal: a shell spells out user-facing copy the registry does not own yet.

ADR 0028 (#284): every user-facing string in a shell comes from
`registry/*.json`, so each platform reads it instead of typing it again.
`registry-owned-literal` (scripts/lint-registry-literals.py) only catches a
literal that already equals a registry string; this rule catches new copy.

It fails on a capitalized string literal in a text position:
  - SwiftUI: `Text`, `Button`, `Label`, `Toggle`, `Section`, `TextField`,
    `SecureField` (first argument), `.navigationTitle`, `.help`.
  - AppKit: `NSMenuItem(title:)`, `.title =`, `.placeholderString =`.
  - Compose (Android UI): `Text("…")` and `Text(text = "…")`.
in `Septena/Shell`, `Septask`, `android/app/src/main` and `android/ui/src`.

Platform button chrome (`Cancel`, `Done`, ...) is out of scope, as in
registry-owned-literal: the system words come translated from the catalog.

Exceptions:
  - `// septena-lint:allow shell-copy-literal` on the line, with the reason in
    a comment above.
  - `scripts/shell-copy-allowlist.json`: copy that predates the rule, each
    entry with a reason and the issue that moves it into the registry. An
    entry that no longer matches fails, so the list only shrinks.

Prints one `path:line: "literal"` per violation; prints nothing when clean.
`--seed` prints allowlist entries for the current hits instead.
"""
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SWIFT_DIRS = ["Septena/Shell", "Septask"]
KOTLIN_DIRS = ["android/app/src/main", "android/ui/src"]
RULE = "septena-lint:allow shell-copy-literal"
ALLOWLIST = "scripts/shell-copy-allowlist.json"
# A plain literal body: no interpolation, only \" and \\ escapes.
BODY = r'"((?:[^"\\\n]|\\["\\])*)"'
SWIFT_POSITIONS = [
    re.compile(r'\b(?:Text|Button|Label|Toggle|Section|TextField|SecureField)\(\s*' + BODY),
    re.compile(r'\.(?:navigationTitle|help)\(\s*' + BODY),
    re.compile(r'\bNSMenuItem\(\s*title:\s*' + BODY),
    re.compile(r'\.(?:title|placeholderString)\s*=\s*' + BODY),
]
KOTLIN_POSITIONS = [
    re.compile(r'\bText\(\s*(?:text\s*=\s*)?' + BODY),
]
# The same chrome set as lint-registry-literals.py.
CHROME = {"Cancel", "Done", "OK", "Add", "Clear", "Copy", "Delete", "Open", "Close", "Save", "Edit", "Continue"}


def is_copy(text):
    return len(text) >= 2 and text[:1].isupper() and text not in CHROME


def strip_comment(line):
    # Drop a trailing `//` comment that is outside a string literal.
    in_str = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_str:
            i += 2
            continue
        if c == '"':
            in_str = not in_str
        elif not in_str and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def scan(dirs, ext, positions):
    """Yield (rel, line_no, text) for each user-facing literal in `dirs`."""
    for d in dirs:
        for dirpath, dirnames, files in os.walk(os.path.join(ROOT, d)):
            dirnames[:] = sorted(x for x in dirnames if x not in ("generated", "build", "test", "androidTest"))
            for name in sorted(files):
                if not name.endswith(ext):
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, ROOT)
                with open(full, encoding="utf-8") as f:
                    in_block = False
                    for n, raw in enumerate(f, 1):
                        line = raw.rstrip("\n")
                        s = line.strip()
                        if in_block:
                            if "*/" in s:
                                in_block = False
                            continue
                        if s.startswith("/*"):
                            in_block = "*/" not in s
                            continue
                        if s.startswith("//") or s.startswith("*") or RULE in line:
                            continue
                        code = strip_comment(line)
                        for pattern in positions:
                            for m in pattern.finditer(code):
                                text = m.group(1).replace('\\"', '"')
                                if is_copy(text):
                                    yield (rel, n, text)


def hits():
    return list(scan(SWIFT_DIRS, ".swift", SWIFT_POSITIONS)) + list(scan(KOTLIN_DIRS, ".kt", KOTLIN_POSITIONS))


def main():
    found = hits()
    if "--seed" in sys.argv:
        seen = []
        for rel, _, text in found:
            if (rel, text) not in seen:
                seen.append((rel, text))
        print(json.dumps([{"file": rel, "literal": text} for rel, text in seen], ensure_ascii=False, indent=2))
        return
    with open(os.path.join(ROOT, ALLOWLIST), encoding="utf-8") as f:
        data = json.load(f)
    entries = data.get("entries", [])
    reasons = {k: v for k, v in data.get("reasons", {}).items()}
    allowed = {(e["file"], e["literal"]) for e in entries}
    problems = []
    for e in entries:
        why = e.get("reason") or reasons.get(e.get("reasonId", ""), {}).get("reason")
        issue = e.get("issue") or reasons.get(e.get("reasonId", ""), {}).get("issue")
        if not why or not issue:
            problems.append(f'{ALLOWLIST}: entry {e.get("file")} "{e.get("literal")}" needs a reason and an issue')
    matched = set()
    for rel, n, text in found:
        if (rel, text) in allowed:
            matched.add((rel, text))
            continue
        problems.append(f'{rel}:{n}: "{text}"')
    for e in entries:
        if (e["file"], e["literal"]) not in matched:
            problems.append(f'{ALLOWLIST}: {e["file"]} "{e["literal"]}" no longer appears; remove the entry')
    for p in problems:
        print(p)


if __name__ == "__main__":
    main()
