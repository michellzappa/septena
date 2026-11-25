import type { StoreSnapshot } from "./types";

function triggerDownload(filename: string, mimeType: string, content: string): void {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export function exportAsJson(snapshot: StoreSnapshot): void {
  const payload = {
    exportedAt: new Date().toISOString(),
    version: 1,
    areas: snapshot.areas.filter((a) => !a.deletedAt),
    projects: snapshot.projects.filter((p) => !p.deletedAt),
    tags: snapshot.tags.filter((t) => !t.deletedAt),
    tasks: snapshot.tasks.filter((t) => !t.deletedAt),
    checklistItems: snapshot.checklistItems.filter((c) => !c.deletedAt),
    taskRefs: snapshot.taskRefs.filter((r) => !r.deletedAt),
  };
  triggerDownload(
    `septena-export-${new Date().toISOString().slice(0, 10)}.json`,
    "application/json;charset=utf-8",
    JSON.stringify(payload, null, 2),
  );
}

export function exportAsMarkdown(snapshot: StoreSnapshot): void {
  const areaById = new Map(snapshot.areas.map((a) => [a.id, a]));
  const projectById = new Map(snapshot.projects.map((p) => [p.id, p]));
  const itemsByTask = new Map<string, typeof snapshot.checklistItems>();
  for (const c of snapshot.checklistItems) {
    if (c.deletedAt) continue;
    const list = itemsByTask.get(c.taskId) ?? [];
    list.push(c);
    itemsByTask.set(c.taskId, list);
  }

  const lines: string[] = [`# Septena Export (${new Date().toISOString().slice(0, 10)})`, ""];
  const openTasks = snapshot.tasks.filter((t) => !t.deletedAt && t.status === "open" && t.kind !== "heading");
  const doneTasks = snapshot.tasks.filter((t) => !t.deletedAt && t.status === "done" && t.kind !== "heading");

  const renderTask = (t: (typeof snapshot.tasks)[number]) => {
    const box = t.status === "done" ? "[x]" : "[ ]";
    const meta: string[] = [];
    if (t.today) meta.push("Today");
    if (t.scheduled) meta.push(`when:${t.scheduled}`);
    if (t.deadline) meta.push(`due:${t.deadline}`);
    const proj = t.project ? projectById.get(t.project)?.title : null;
    const area = t.area ? areaById.get(t.area)?.title : null;
    if (proj) meta.push(`#${proj}`);
    else if (area) meta.push(`@${area}`);
    lines.push(`- ${box} ${t.title}${meta.length ? ` (${meta.join(" · ")})` : ""}`);
    if (t.notes) {
      for (const noteLine of t.notes.split("\n")) lines.push(`  > ${noteLine}`);
    }
    for (const c of itemsByTask.get(t.id) ?? []) {
      lines.push(`  - ${c.checked ? "[x]" : "[ ]"} ${c.title}`);
    }
  };

  lines.push("## Open", "");
  openTasks.forEach(renderTask);
  lines.push("", "## Logbook", "");
  doneTasks.forEach(renderTask);

  triggerDownload(
    `septena-export-${new Date().toISOString().slice(0, 10)}.md`,
    "text/markdown;charset=utf-8",
    lines.join("\n") + "\n",
  );
}

function csvCell(v: unknown): string {
  const s = v === null || v === undefined ? "" : String(v);
  if (/[",\n\r]/.test(s)) return `"${s.replaceAll('"', '""')}"`;
  return s;
}

export function exportAsCsv(snapshot: StoreSnapshot): void {
  const areaById = new Map(snapshot.areas.map((a) => [a.id, a.title]));
  const projectById = new Map(snapshot.projects.map((p) => [p.id, p.title]));
  const headers = ["id", "title", "status", "today", "starred", "scheduled", "deadline", "area", "project", "notes", "createdAt", "completedAt"];
  const rows = [
    headers.join(","),
    ...snapshot.tasks
      .filter((t) => !t.deletedAt && t.kind !== "heading")
      .map((t) =>
        [
          t.id,
          t.title,
          t.status,
          Boolean(t.today),
          Boolean(t.starred),
          t.scheduled ?? "",
          t.deadline ?? "",
          t.area ? (areaById.get(t.area) ?? t.area) : "",
          t.project ? (projectById.get(t.project) ?? t.project) : "",
          t.notes ?? "",
          t.createdAt ?? "",
          t.completedAt ?? "",
        ]
          .map(csvCell)
          .join(","),
      ),
  ];
  triggerDownload(
    `septena-export-${new Date().toISOString().slice(0, 10)}.csv`,
    "text/csv;charset=utf-8",
    rows.join("\n") + "\n",
  );
}
