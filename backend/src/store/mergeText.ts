// Three-way merge of a long text (notes). Two people who edit the same notes
// at the same time both keep their words: changes in different places
// combine, and where both changed one place, both versions stay.
//
// `theirs` is what is stored now, `mine` the write that just arrived, `base`
// the text that write was made from. Only the backend merges: a client sends
// the base with its write (`base` on an upsert op) and pulls the result.

/// Above this many table cells a hunk is not compared inside: it counts as
/// changed as a whole.
const MAX_CELLS = 2_000_000;

type Chunk = { base: string[]; theirs: string[]; mine: string[] };

/// For every base index the index it matches in `other`, or -1 (longest
/// common subsequence).
function matches(base: string[], other: string[]): number[] {
  const out = new Array<number>(base.length).fill(-1);
  let start = 0;
  while (start < base.length && start < other.length && base[start] === other[start]) {
    out[start] = start;
    start++;
  }
  let endB = base.length;
  let endO = other.length;
  while (endB > start && endO > start && base[endB - 1] === other[endO - 1]) {
    endB--;
    endO--;
    out[endB] = endO;
  }
  const n = endB - start;
  const m = endO - start;
  if (n === 0 || m === 0 || n * m > MAX_CELLS) return out;
  const width = m + 1;
  const table = new Uint32Array((n + 1) * width);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      table[i * width + j] = base[start + i] === other[start + j]
        ? table[(i + 1) * width + j + 1] + 1
        : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  for (let i = 0, j = 0; i < n && j < m;) {
    if (base[start + i] === other[start + j]) {
      out[start + i] = start + j;
      i++;
      j++;
    } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) i++;
    else j++;
  }
  return out;
}

/// Cuts the three texts at the tokens all of them share. A chunk whose three
/// sides are equal is one such token.
function chunks(base: string[], theirs: string[], mine: string[]): Chunk[] {
  const inTheirs = matches(base, theirs);
  const inMine = matches(base, mine);
  const out: Chunk[] = [];
  let b = 0;
  let t = 0;
  let m = 0;
  for (let i = 0; i <= base.length; i++) {
    const atEnd = i === base.length;
    const toT = atEnd ? theirs.length : inTheirs[i];
    const toM = atEnd ? mine.length : inMine[i];
    if (toT < t || toM < m) continue;
    if (i > b || toT > t || toM > m) {
      out.push({ base: base.slice(b, i), theirs: theirs.slice(t, toT), mine: mine.slice(m, toM) });
    }
    if (!atEnd) out.push({ base: [base[i]], theirs: [base[i]], mine: [base[i]] });
    b = i + 1;
    t = toT + 1;
    m = toM + 1;
  }
  return out;
}

const same = (a: string[], b: string[]) => a.length === b.length && a.every((v, i) => v === b[i]);

/// The merged tokens, or null where both sides changed one place.
function merge(base: string[], theirs: string[], mine: string[], onConflict: (c: Chunk) => string[] | null): string[] | null {
  const out: string[] = [];
  for (const c of chunks(base, theirs, mine)) {
    const picked = same(c.theirs, c.base) ? c.mine
      : same(c.mine, c.base) || same(c.theirs, c.mine) ? c.theirs
      : onConflict(c);
    if (!picked) return null;
    out.push(...picked);
  }
  return out;
}

const words = (text: string) => text.match(/\s+|[^\s]+/g) ?? [];

/// Both changed these lines. Words that differ in different places combine;
/// otherwise both versions stay, the stored one first.
function bothLines(c: Chunk): string[] {
  if (c.base.length) {
    const combined = merge(words(c.base.join("\n")), words(c.theirs.join("\n")), words(c.mine.join("\n")), () => null);
    if (combined) return combined.join("").split("\n");
  }
  const theirs = c.theirs.join("\n");
  const mine = c.mine.join("\n");
  if (theirs.includes(mine)) return c.theirs;
  if (mine.includes(theirs)) return c.mine;
  return [...c.theirs, ...c.mine];
}

export function mergeText(base: string, theirs: string, mine: string): string {
  if (theirs === base || theirs === mine) return mine;
  if (mine === base) return theirs;
  return merge(base.split("\n"), theirs.split("\n"), mine.split("\n"), bothLines)!.join("\n");
}

/// The same for a nullable column. A text that would be longer than `max`
/// does not merge: the newer write wins and the change log keeps the other.
export function mergeNotes(base: string | null, theirs: string | null, mine: string | null, max: number): string | null {
  const merged = mergeText(base ?? "", theirs ?? "", mine ?? "");
  if (merged.length > max) return mine;
  return merged === "" ? null : merged;
}
