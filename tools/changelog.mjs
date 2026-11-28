// The task app's changelog: one file per user-visible change in
// changelog/updates/ (changelog/README.md). septena.app/changelog renders the
// JSON this prints (../site/scripts/sync-changelog.mjs).
//
// Usage: node tools/changelog.mjs           prints the updates, newest first
//        node tools/changelog.mjs --check   checks every update file (exit 1 on a problem)
//        node tools/changelog.mjs --json    prints the updates as JSON, newest first
//        node tools/changelog.mjs --activity  commits per day as JSON (septena.app/changelog)
//        node tools/changelog.mjs --behind  feat/fix/polish commits newer than the newest update
// Node built-ins only.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const KINDS = ['new', 'improved', 'fixed', 'removed'];
export const PLATFORMS = ['ios', 'ipad', 'mac', 'watch'];
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

// Development activity: commit counts from git, no subjects (the page is public
// and subjects carry internal names). Merges are left out.

const ACTIVITY_DAYS = 112; // 16 weeks
const TYPE_RE = /^(feat|fix|polish|docs)(\(|:|!)/;

function gitLog(args) {
  return execFileSync('git', ['log', '--no-merges', ...args], { cwd: ROOT, encoding: 'utf8' })
    .split('\n')
    .filter(Boolean);
}

/** One commit type: feat, fix, polish, docs, or other. */
export function commitType(subject) {
  const m = TYPE_RE.exec(subject);
  if (m) return m[1];
  if (/^[A-Z]{1,3}\d+:/.test(subject)) return 'feat'; // factory phase commits ("ST1: ...")
  return 'other';
}

export function activity(now = new Date()) {
  const start = new Date(now);
  start.setUTCDate(start.getUTCDate() - (ACTIVITY_DAYS - 1));
  const from = start.toISOString().slice(0, 10);
  const byDay = new Map();
  for (const line of gitLog([`--since=${from}T00:00:00`, '--format=%ad%x09%s', '--date=short'])) {
    const [date, subject = ''] = line.split('\t');
    if (date < from) continue;
    const day = byDay.get(date) ?? { feat: 0, fix: 0, polish: 0, docs: 0, other: 0 };
    day[commitType(subject)] += 1;
    byDay.set(date, day);
  }
  const days = [];
  for (let d = new Date(`${from}T00:00:00Z`); days.length < ACTIVITY_DAYS; d.setUTCDate(d.getUTCDate() + 1)) {
    const date = d.toISOString().slice(0, 10);
    const c = byDay.get(date) ?? { feat: 0, fix: 0, polish: 0, docs: 0, other: 0 };
    days.push({ date, total: c.feat + c.fix + c.polish + c.docs + c.other, ...c });
  }
  const last = execFileSync('git', ['log', '-1', '--format=%cI'], { cwd: ROOT, encoding: 'utf8' }).trim();
  const commits = Number(execFileSync('git', ['rev-list', '--count', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim());
  return { generatedAt: now.toISOString(), lastCommitAt: last || null, commits, days };
}

/** User-facing commits (feat, fix, polish) after the newest update's day. */
export function behind(updates) {
  const newest = updates.map((u) => u.date).sort().at(-1);
  if (!newest) return [];
  return gitLog([`--since=${newest}T23:59:59`, '--format=%ad %s', '--date=short']).filter((l) =>
    ['feat', 'fix', 'polish'].includes(commitType(l.slice(11))),
  );
}

function main(argv) {
  if (argv.includes('--activity')) {
    console.log(JSON.stringify(activity(), null, 2));
    return;
  }
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
  if (argv.includes('--behind')) {
    const missing = behind(updates);
    for (const l of missing) console.log(l);
    if (missing.length) console.error(`changelog: ${missing.length} user-facing commit(s) after the newest update. Write updates for the visible ones.`);
    return;
  }
  const sorted = updates.sort(newestFirst);
  if (argv.includes('--json')) {
    console.log(JSON.stringify(sorted.map(toJSON), null, 2));
    return;
  }
  for (const u of sorted) console.log(`${u.date}  ${u.kind.padEnd(8)} ${toJSON(u).headline}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv.slice(2));
