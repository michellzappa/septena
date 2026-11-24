#!/usr/bin/env python3
"""Writes core/crates/septena-core/src/nfc_table.rs: the canonical data that
nfc.rs needs. NFC never changes for an assigned character, so this runs again
only to add the characters of a newer Unicode version.

Usage: python3 scripts/gen-nfc-table.py
"""
import pathlib
import unicodedata as u

compose, decompose, classes = [], [], []
for c in range(0x110000):
    if 0xD800 <= c <= 0xDFFF or 0xAC00 <= c <= 0xD7A3:
        continue  # Surrogates; Hangul syllables are arithmetic.
    k = u.combining(chr(c))
    if k:
        if classes and classes[-1][1] == c - 1 and classes[-1][2] == k:
            classes[-1][1] = c
        else:
            classes.append([c, c, k])
    d = u.decomposition(chr(c))
    if not d or d.startswith("<"):
        continue
    parts = [int(x, 16) for x in d.split()]
    if len(parts) == 2 and u.normalize("NFC", chr(parts[0]) + chr(parts[1])) == chr(c):
        compose.append([c, *parts])
    else:
        decompose.append([c, *(parts + [0])[:2]])


def table(doc, name, kind, rows):
    out = [f"/// {doc}", "#[rustfmt::skip]", f"pub(crate) static {name}: &[{kind}] = &["]
    line = "   "
    for row in rows:
        cell = " (" + ", ".join(f"0x{v:X}" for v in row[:-1]) + (f", {row[-1]})," if "u8" in kind else f", 0x{row[-1]:X}),")
        if len(line) + len(cell) > 118:
            out.append(line)
            line = "   "
        line += cell
    return out + [line, "];", ""]


lines = [
    "// GENERATED FILE — DO NOT EDIT BY HAND.",
    f"// Regenerate: python3 scripts/gen-nfc-table.py (Unicode {u.unidata_version}).",
    "",
    *table("`(composed, first, second)`, sorted by the first column.", "COMPOSE", "(u32, u32, u32)", compose),
    *table("`(character, first, second or 0)`: decomposed, never composed again. Sorted.", "DECOMPOSE", "(u32, u32, u32)", decompose),
    *table("`(first, last, canonical combining class)`, sorted. Other characters have class 0.", "CLASSES", "(u32, u32, u8)", classes),
]
target = pathlib.Path(__file__).resolve().parent.parent / "core/crates/septena-core/src/nfc_table.rs"
target.write_text("\n".join(lines).rstrip() + "\n")
print(f"{len(compose)} compositions, {len(decompose)} decompositions, {len(classes)} class ranges")
