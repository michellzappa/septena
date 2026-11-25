#!/usr/bin/env python3
"""registry-owned-literal: a shared shell file spells out copy the registry owns.

ADR 0020: every string that more than one shell shows comes from
`registry/*.json`, so it is translated once and the SwiftUI and AppKit shells
cannot drift. This check reads every registry string (`registry/l10n/en.json`,
written by `node scripts/gen-registries.mjs`) and fails on a Swift string
literal in `Septena/Shell/` or `Septask/` whose text is exactly one of them.
Read the generated value instead (`RegistryActions.title`, `RegistrySettings.
label`, `RegistryPrompts.prompt`, ...).

The Swift (`Septena/Shell`, `Septask`, `SeptenaCore`, ADR 0028, #287) and
Android (`android/app`, `android/ui`, ADR 0028, #283) UIs also get
`registry-id-literal`: a string literal that equals a registry action,
destination or surface ID fails. Pass the generated typed ID enum on Swift
(`RegistryActionID`, `RegistryDestinationID`, `RegistryPromptID`,
`RegistryNoticeID`, `RegistryTaskAttributeID`, `RegistryFirstRunStepID`, ...)
or the generated constant on Kotlin (`RegistryActionIds`,
`RegistryDestinationIds`, `RegistryPromptIds`, `RegistryPlacesScreenIds`,
`RegistryNoticeIds`, `RegistryTaskDetail`, ...).

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
SWIFT_ID_DIRS = ["Septena/Shell", "Septask", "SeptenaCore"]
KOTLIN_DIRS = ["android/app/src/main", "android/ui/src"]
RULE = "septena-lint:allow registry-owned-literal"
ID_RULE = "septena-lint:allow registry-id-literal"
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


def registry_ids():
    """Action, destination and surface IDs that a Kotlin UI must not spell out.

    Only IDs with a capital letter or a dot: a plain word ("notes", "today")
    also names JSON fields and enum values, so a literal of it proves nothing.
    """
    def load(name):
        with open(os.path.join(ROOT, "registry", name), encoding="utf-8") as f:
            return json.load(f)

    ids = set(load("actions.json")["actions"].keys())
    ids |= {d["id"] for d in load("destinations.json")["destinations"]}

    def walk(v):
        if isinstance(v, dict):
            if isinstance(v.get("id"), str):
                ids.add(v["id"])
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(load("surfaces.json"))
    return {i for i in ids if "." in i or any(c.isupper() for c in i)}


def scan(dirs, ext, check):
    """Yield (rel, line_no, text) for each literal in `dirs` that `check` flags."""
    for d in dirs:
        for dirpath, dirnames, files in os.walk(os.path.join(ROOT, d)):
            dirnames[:] = [x for x in dirnames if x.lower() not in ("generated", "build")]
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
                        if s.startswith("//") or s.startswith("*"):
                            continue
                        if re.search(r'\b(Log\.|logger\.|print\(|println\(|os_log|assertionFailure|preconditionFailure|fatalError|error\()', line):
                            continue
                        for m in LITERAL.finditer(strip_comment(line)):
                            text = m.group(1).replace('\\"', '"')
                            if check(text, line):
                                yield (rel, n, text)


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
    ids = registry_ids()
    copy = lambda text, line: RULE not in line and text in owned
    hits = list(scan(DIRS, ".swift", copy)) + list(scan(KOTLIN_DIRS, ".kt", copy))
    id_check = lambda text, line: ID_RULE not in line and text in ids
    id_hits = list(scan(SWIFT_ID_DIRS, ".swift", id_check)) + list(scan(KOTLIN_DIRS, ".kt", id_check))

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
    for rel, n, text in id_hits:
        problems.append(f'{rel}:{n}: registry-id-literal "{text}"')
    if "--all" in sys.argv:
        for rel, n, text in hits:
            print(f'{rel}:{n}: "{text}"')
        return
    for p in problems:
        print(p)


if __name__ == "__main__":
    main()
