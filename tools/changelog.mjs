// The task app's changelog: one file per user-visible change in
// changelog/updates/ (changelog/README.md). septena.app/changelog renders the
// JSON this prints (../septena-site/scripts/sync-changelog.mjs).
//
// Usage: node tools/changelog.mjs           prints the updates, newest first
//        node tools/changelog.mjs --check   checks every update file (exit 1 on a problem)
//        node tools/changelog.mjs --json    prints the updates as JSON, newest first
// Node built-ins only.

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const KINDS = ['new', 'improved', 'fixed', 'removed'];
export const PLATFORMS = ['ios', 'ipad', 'mac'];
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const UPDATES = join(ROOT, 'changelog', 'updates');
const FILE_RE = /^\d{4}-\d{2}-\d{2}-[a-z0-9-]+\.md$/;
const REF_RE = /^[a-z0-9-]+#\d+$/;

/** A `---` block of `key: value` lines (a value in `[a, b]` is a list), then the body. */
export function parseUpdate(text) {
  const match = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(text.replace(/\r\n/g, '\n'));
  if (!match) throw new Error('no front matter');
  const fields = {};
  for (const line of match[1].split('\n').filter(Boolean)) {
    const at = line.indexOf(':');
    if (at < 1) throw new Error(`bad line "${line}"`);
    const key = line.slice(0, at).trim();
    const raw = line.slice(at + 1).trim();
    fields[key] = raw.startsWith('[')
      ? raw.slice(1, -1).split(',').map((s) => s.trim()).filter(Boolean)
      : raw;
  }
  return { ...fields, body: match[2].trim() };
}

export function updateProblems(file, u) {
  const problems = [];
  const id = file.replace(/\.md$/, '');
  if (!FILE_RE.test(file)) problems.push(`${file}: name it YYYY-MM-DD-slug.md (lower case)`);
  if (u.id !== id) problems.push(`${file}: id must be "${id}"`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(u.date ?? '') || !id.startsWith(u.date)) {
    problems.push(`${file}: date must be YYYY-MM-DD and match the file name`);
  }
  if (!KINDS.includes(u.kind)) problems.push(`${file}: kind must be one of ${KINDS.join(', ')}`);
  const platforms = u.platforms ?? [];
  if (!Array.isArray(platforms) || platforms.length === 0 || platforms.some((p) => !PLATFORMS.includes(p))) {
    problems.push(`${file}: platforms must list one or more of ${PLATFORMS.join(', ')}`);
  }
  const refs = u.refs ?? [];
  if (!Array.isArray(refs) || refs.some((r) => !REF_RE.test(r))) problems.push(`${file}: refs must be a list like [septena#87]`);
  if ('version' in u) problems.push(`${file}: no version field (the release step assigns it)`);
  if (!/^\*\*[^*]+\*\*/.test(u.body)) problems.push(`${file}: the body starts with a bold headline`);
  if (/—/.test(u.body)) problems.push(`${file}: no em dashes in public copy`);
  return problems;
}

export function readUpdates() {
  if (!existsSync(UPDATES)) return [];
  return readdirSync(UPDATES)
    .filter((f) => f.endsWith('.md'))
    .map((file) => {
      try {
        return { file, ...parseUpdate(readFileSync(join(UPDATES, file), 'utf8')) };
      } catch (error) {
        return { file, error: `${file}: ${error.message}` };
      }
    });
}

/** Newest first; inside a day, by id. */
const newestFirst = (a, b) => (a.date === b.date ? a.id.localeCompare(b.id) : b.date.localeCompare(a.date));

/** The site's shape: the headline split from the detail. */
export function toJSON(u) {
  const match = /^\*\*([^*]+)\*\*\s*([\s\S]*)$/.exec(u.body);
  const out = {
    id: u.id,
    date: u.date,
    kind: u.kind,
    platforms: u.platforms,
    refs: u.refs ?? [],
    headline: match[1].trim(),
    detail: match[2].trim() || null,
  };
  if (u.feature) out.feature = u.feature;
  return out;
}

function main(argv) {
  const updates = readUpdates();
  const problems = updates.flatMap((u) => (u.error ? [u.error] : updateProblems(u.file, u)));
  if (argv.includes('--check')) {
    for (const p of problems) console.error(p);
    if (problems.length) process.exit(1);
    console.log(`changelog: ${updates.length} updates OK`);
    return;
  }
  if (problems.length) {
    for (const p of problems) console.error(p);
    process.exit(1);
  }
  const sorted = updates.sort(newestFirst);
  if (argv.includes('--json')) {
    console.log(JSON.stringify(sorted.map(toJSON), null, 2));
    return;
  }
  for (const u of sorted) console.log(`${u.date}  ${u.kind.padEnd(8)} ${toJSON(u).headline}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv.slice(2));
