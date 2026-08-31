#!/usr/bin/env python3
"""Row tap-target guardrail — the `row-dead-zone` rule of scripts/lint-design.sh.

`.buttonStyle(.plain)` (and the plain-derived row styles) opt a Button out of
the list cell's tap target, so ONLY the drawn label is hit-testable: the
`Spacer()` and every trailing gap become dead zones, and a tap near the right
edge of the row silently misses. `LogRow` carries `.contentShape(Rectangle())`
for exactly this reason — every other full-width row Button needs it too.

Prints one `path:line` per violation and exits 1 when any remain. Not
expressible as a grep rule: the label, its modifier chain, and the button style
sit on different lines, so the check has to read the brace structure.
"""

import os
import re
import sys

ROOTS = ("Septena", "Septask", "SeptenaCore")
# Row components that already carry their own content shape.
ROW_VIEWS = r"\b(LogRow|LogEntryRow|CheckableRow|TaskRow)\b"
# Button styles that drop the cell-wide tap target.
PLAIN_STYLES = ("buttonStyle(.plain)", "PlainHoverRowButtonStyle", "InertButtonStyle")
ALLOW = "septena-lint:allow row-dead-zone"


def block_end(src, i):
    """Index of the `}` matching the `{` at `i`."""
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return j
    return len(src) - 1


def chain_after(src, j):
    """The modifier lines that follow the closing brace at `j`."""
    lines = src[j + 1: j + 1200].splitlines()
    if lines and lines[0].strip() == "":
        lines = lines[1:]              # remainder of the closing-brace line
    out = []
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("."):
            break
        out.append(stripped)
    return "\n".join(out)


def paren_end(src, i):
    """Index of the `)` matching the `(` at `i`."""
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    return len(src) - 1


def violations(path, src):
    lines = src.splitlines()
    for m in re.finditer(r"\bButton\b\s*[({]", src):
        opener = src.find("{", m.start())
        if src[m.end() - 1] == "(":       # Button(…) { … } — skip the argument list
            opener = src.find("{", paren_end(src, m.end() - 1))
        if opener < 0:
            continue
        end = block_end(src, opener)
        label = src[opener: end + 1]
        tail = src[end + 1: end + 400]
        if re.match(r"\s*label\s*:\s*\{", tail):   # the action closure came first
            opener = end + 1 + tail.find("{")
            end = block_end(src, opener)
            label = src[opener: end + 1]
        chain = chain_after(src, end)
        if not any(style in chain for style in PLAIN_STYLES):
            continue
        if "Spacer()" not in label:
            continue
        if "contentShape" in label or "contentShape" in chain:
            continue
        # An opaque background is itself hit-testable, so the row is covered.
        if ".background(" in label or ".background {" in label:
            continue
        if re.search(ROW_VIEWS, label):
            continue
        line = src[: m.start()].count("\n") + 1
        if ALLOW in lines[line - 1]:
            continue
        yield f"{path}:{line}"


def main():
    hits = []
    for root in ROOTS:
        for dirpath, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8") as handle:
                    hits.extend(violations(path, handle.read()))
    for hit in hits:
        print(hit)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
