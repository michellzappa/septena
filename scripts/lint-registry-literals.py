#!/usr/bin/env python3
"""registry-owned-literal: a shared shell file spells out copy the registry owns.

ADR 0020: every string that more than one shell shows comes from
`registry/*.json`, so it is translated once and the SwiftUI and AppKit shells
cannot drift. This check reads every registry string (`registry/l10n/en.json`,
written by `node scripts/gen-registries.mjs`) and fails on a Swift string
literal in `Septena/Shell/` or `Septask/` whose text is exactly one of them.
Read the generated value instead (`RegistryActions.title`, `RegistrySettings.
label`, `RegistryPrompts.prompt`, ...).

Exceptions:
  - `// septena-lint:allow registry-owned-literal` on the line, with the reason
    in a comment above (a string that only matches by accident).
  - `scripts/registry-literal-allowlist.json`: known drift, each entry with a
    reason and the issue that removes it. An entry that no longer matches
    fails, so the list only shrinks.

Prints one `path:line: "literal"` per violation; prints nothing when clean.
"""
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DIRS = ["Septena/Shell", "Septask"]
RULE = "septena-lint:allow registry-owned-literal"
# A plain literal: no interpolation, no escapes we would have to decode.
LITERAL = re.compile(r'(?<![\\#])"((?:[^"\\\n]|\\["\\])*)"')
# Copy short enough to collide with identifiers, keys and log text.
MIN_LEN = 3
# Platform button chrome. Sheets and alerts outside a registry surface use the
# system words, which the string catalog already translates; the registry owns
# them only inside its own prompts, and those render from the registry.
CHROME = {"Cancel", "Done", "OK", "Add", "Clear", "Copy", "Delete", "Open", "Close", "Save", "Edit", "Continue"}


def registry_strings():
    with open(os.path.join(ROOT, "registry/l10n/en.json"), encoding="utf-8") as f:
        en = json.load(f)
    out = set()
    for key, text in en.items():
        for s in (key, text):
            if isinstance(s, str) and s not in CHROME and len(s) >= MIN_LEN and "%" not in s and "{" not in s and any(c.isupper() for c in s[:1]):
                out.add(s)
    return out


def allowlist():
    path = os.path.join(ROOT, "scripts/registry-literal-allowlist.json")
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return data.get("entries", [])


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


def main():
    owned = registry_strings()
    hits = []
    for d in DIRS:
        for dirpath, _, files in os.walk(os.path.join(ROOT, d)):
            for name in sorted(files):
                if not name.endswith(".swift"):
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
                        if s.startswith("//") or RULE in line:
                            continue
                        if re.search(r'\b(Log\.|logger\.|print\(|os_log|assertionFailure|preconditionFailure|fatalError)', line):
                            continue
                        for m in LITERAL.finditer(strip_comment(line)):
                            text = m.group(1).replace('\\"', '"')
                            if text in owned:
                                hits.append((rel, n, text))

    entries = allowlist()
    allowed = {(e["file"], e["literal"]) for e in entries}
    problems = []
    for e in entries:
        if not e.get("reason") or not e.get("issue"):
            problems.append(f'scripts/registry-literal-allowlist.json: entry {e.get("file")} "{e.get("literal")}" needs "reason" and "issue"')
    matched = set()
    for rel, n, text in hits:
        if (rel, text) in allowed:
            matched.add((rel, text))
            continue
        problems.append(f'{rel}:{n}: "{text}"')
    for e in entries:
        if (e["file"], e["literal"]) not in matched:
            problems.append(f'scripts/registry-literal-allowlist.json: {e["file"]} "{e["literal"]}" no longer appears; remove the entry')
    if "--all" in sys.argv:
        for rel, n, text in hits:
            print(f'{rel}:{n}: "{text}"')
        return
    for p in problems:
        print(p)


if __name__ == "__main__":
    main()
