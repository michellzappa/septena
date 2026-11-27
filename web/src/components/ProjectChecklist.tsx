"use client";

import { useMemo, useState } from "react";
import { callCore, occurrenceId } from "../lib/core";
import type { ProjectRow, TaskRow } from "../lib/types";
import type { WebSyncEngine } from "../lib/sync/engine";

const groceryGroups: Record<string, string> = {
  produce: "Produce",
  dairy: "Dairy",
  bakery: "Bakery",
  meatSeafood: "Meat & Seafood",
  pantry: "Pantry",
  frozen: "Frozen",
};

interface Layout {
  ungrouped: string[];
  groups: { id: string; items: string[] }[];
  checked: string[];
  matches: string[];
  suggestedGroup: string | null;
}

export function ProjectChecklist({
  project, tasks, engine, toggle, open,
}: {
  project: ProjectRow;
  tasks: TaskRow[];
  engine: WebSyncEngine;
  toggle: (task: TaskRow) => Promise<void>;
  open: (task: TaskRow) => void;
}) {
  const [title, setTitle] = useState("");
  const [group, setGroup] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const rows = useMemo(() => tasks.filter((task) => task.project === project.id && !task.deletedAt)
    .sort((a, b) => (a.position ?? Number.MAX_SAFE_INTEGER) - (b.position ?? Number.MAX_SAFE_INTEGER)
      || String(b.createdAt ?? "").localeCompare(String(a.createdAt ?? ""))
      || a.id.localeCompare(b.id)), [project.id, tasks]);
  const byId = useMemo(() => new Map(rows.map((row) => [row.id, row])), [rows]);
  const headings = useMemo(() => rows.filter((row) => row.kind === "heading"), [rows]);
  const layout = useMemo(() => callCore<Layout>("projectChecklist", {
    rows,
    query: title,
    groceries: project.checklistMode === "groceries",
  }), [project.checklistMode, rows, title]);

  const perform = async (write: () => Promise<unknown>) => {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await write();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : "Couldn’t update this checklist.");
    } finally {
      setBusy(false);
    }
  };

  const add = () => perform(async () => {
    const item = title.trim();
    if (!item) return;
    let heading = group;
    if (!heading && layout.suggestedGroup) {
      const name = groceryGroups[layout.suggestedGroup];
      const id = occurrenceId(`checklist:${project.id}`, layout.suggestedGroup);
      const existing = headings.find((row) => row.id === id || row.title === name);
      const removed = tasks.some((row) => row.id === id && row.deletedAt);
      heading = existing?.id ?? (name && !removed
        ? (await engine.createTask({ id, title: name, kind: "heading", project: project.id })).id
        : null);
    }
    await engine.createTask({ title: item, project: project.id, heading });
    setTitle("");
  });

  const renderRows = (ids: string[]) => ids.flatMap((id) => {
    const row = byId.get(id);
    if (!row) return [];
    const checked = row.status === "checklistChecked";
    return (
      <li key={id} className="flex items-center gap-2 py-2">
        <input type="checkbox" aria-label={row.title} checked={checked} disabled={busy}
          onChange={() => void perform(() => toggle(row))} />
        <button type="button" className="flex-1 text-left" onClick={() => open(row)}>{row.title}</button>
        {headings.length > 0 && (
          <select aria-label={`Group for ${row.title}`} value={row.heading ?? ""} disabled={busy}
            onChange={(event) => {
              const heading = event.target.value || null;
              void perform(() => engine.updateTaskFields(row, { heading }));
            }}>
            <option value="">Ungrouped</option>
            {headings.map((heading) => <option key={heading.id} value={heading.id}>{heading.title}</option>)}
          </select>
        )}
        <button type="button" disabled={busy} aria-label={`Delete ${row.title}`}
          onClick={() => void perform(() => engine.deleteTask(row))}>Delete</button>
      </li>
    );
  });

  return (
    <div className="space-y-4">
      <form className="flex flex-wrap items-center gap-2" onSubmit={(event) => { event.preventDefault(); void add(); }}>
        <input aria-label="Add item" placeholder="Add item" value={title}
          onChange={(event) => setTitle(event.target.value)}
          className="min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-card)] p-2" />
        {headings.length > 0 && (
          <select aria-label="Add to group" value={group ?? ""}
            onChange={(event) => setGroup(event.target.value || null)}>
            <option value="">Choose group</option>
            {headings.map((heading) => <option key={heading.id} value={heading.id}>{heading.title}</option>)}
          </select>
        )}
        <button type="submit" disabled={busy || !title.trim()}>Add {title.trim() ? `“${title.trim()}”` : "item"}</button>
      </form>
      {error && <p role="alert">{error}</p>}
      {layout.matches.length > 0 && (
        <ul aria-label="Matching checklist items">
          {layout.matches.flatMap((id) => {
            const row = byId.get(id);
            if (!row) return [];
            const checked = row.status === "checklistChecked";
            const heading = row.heading ? byId.get(row.heading)?.title : null;
            return <li key={id}>
              <button type="button" disabled={busy || !checked} onClick={() => void perform(async () => {
                await toggle(row);
                setTitle("");
              })}>
                {row.title}{heading ? ` · ${heading}` : ""}{checked ? "" : " · On list"}
              </button>
            </li>;
          })}
        </ul>
      )}
      <ul>{renderRows(layout.ungrouped)}</ul>
      {layout.groups.map((section) => (
        <section key={section.id}>
          <div className="flex items-center gap-3">
            <h3>{byId.get(section.id)?.title}</h3>
            <button type="button" aria-label={`Add item to ${byId.get(section.id)?.title ?? "group"}`}
              onClick={() => setGroup(section.id)}>Add item</button>
          </div>
          <ul>{renderRows(section.items)}</ul>
        </section>
      ))}
      {layout.checked.length > 0 && (
        <details open>
          <summary>Checked</summary>
          <ul>{renderRows(layout.checked)}</ul>
        </details>
      )}
    </div>
  );
}
