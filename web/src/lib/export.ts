import type {
  AreaRow,
  ChecklistItemRow,
  ProjectRow,
  StoreSnapshot,
  TagRow,
  TaskRefRow,
  TaskRow,
} from "./types";

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

export interface ParsedBackupPreview {
  areas: AreaRow[];
  projects: ProjectRow[];
  tags: TagRow[];
  tasks: TaskRow[];
  checklistItems: ChecklistItemRow[];
  taskRefs: TaskRefRow[];
  skippedNonTaskCount: number;
}

function asArray(v: unknown): Record<string, unknown>[] {
  if (!Array.isArray(v)) return [];
  return v.filter((x): x is Record<string, unknown> => Boolean(x && typeof x === "object" && !Array.isArray(x)));
}

/**
 * Parses a Septena JSON backup (either web export or Apple/Android export shapes)
 * and produces a validated preview before anything is written or synced.
 */
export function parseImportJson(rawText: string): ParsedBackupPreview {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawText);
  } catch {
    throw new Error("That file is not valid JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Expected a Septena JSON backup object.");
  }
  const obj = parsed as Record<string, unknown>;

  const rawAreas = asArray(obj.areas);
  const rawProjects = asArray(obj.projects);
  const rawTags = asArray(obj.tags);
  const rawTasks = asArray(obj.tasks);
  const rawChecklists = asArray(obj.checklistItems ?? obj.checklists);
  const rawRefs = asArray(obj.taskRefs ?? obj.refs);

  const areas: AreaRow[] = rawAreas
    .filter((a) => typeof a.id === "string" && typeof a.title === "string" && a.title.trim())
    .map((a) => ({
      id: String(a.id),
      title: String(a.title).trim(),
      context: typeof a.context === "string" ? a.context : null,
      emoji: typeof a.emoji === "string" ? a.emoji : null,
      position: typeof a.position === "number" ? a.position : null,
    }));

  const projects: ProjectRow[] = rawProjects
    .filter((p) => typeof p.id === "string" && typeof p.title === "string" && p.title.trim())
    .map((p) => ({
      id: String(p.id),
      title: String(p.title).trim(),
      status: p.status === "done" || p.status === "cancelled" ? p.status : "active",
      checklistMode: p.checklistMode === "plain" || p.checklistMode === "groceries" ? p.checklistMode : null,
      area: typeof p.area === "string" ? p.area : null,
      notes: typeof p.notes === "string" ? p.notes : null,
      created: typeof p.created === "string" ? p.created : null,
      position: typeof p.position === "number" ? p.position : null,
    }));

  const tags: TagRow[] = rawTags
    .filter((t) => typeof t.id === "string" && typeof t.name === "string" && t.name.trim())
    .map((t) => ({
      id: String(t.id),
      name: String(t.name).trim(),
      color: typeof t.color === "string" ? t.color : null,
      position: typeof t.position === "number" ? t.position : null,
    }));

  const tasks: TaskRow[] = rawTasks
    .filter((t) => typeof t.id === "string" && typeof t.title === "string" && t.title.trim())
    .map((t) => ({
      id: String(t.id),
      title: String(t.title).trim(),
      status: t.status === "done" || t.status === "cancelled" || (t.status === "checklistChecked" || t.status === "repeatExpired") ? t.status : "open",
      kind: t.kind === "heading" ? "heading" : null,
      heading: typeof t.heading === "string" ? t.heading : null,
      area: typeof t.area === "string" ? t.area : null,
      project: typeof t.project === "string" ? t.project : null,
      notes: typeof t.notes === "string" ? t.notes : null,
      today: Boolean(t.today),
      todaySetOn: typeof t.todaySetOn === "string" ? t.todaySetOn : null,
      starred: Boolean(t.starred),
      scheduled: typeof t.scheduled === "string" ? t.scheduled : null,
      deadline: typeof t.deadline === "string" ? t.deadline : null,
      startTime: typeof t.startTime === "string" ? t.startTime : null,
      durationMinutes: typeof t.durationMinutes === "number" ? t.durationMinutes : null,
      tags: Array.isArray(t.tags) ? t.tags.filter((x): x is string => typeof x === "string") : null,
      position: typeof t.position === "number" ? t.position : null,
      todayPosition: typeof t.todayPosition === "number" ? t.todayPosition : null,
      created: typeof t.created === "string" ? t.created : null,
      createdAt: typeof t.createdAt === "string" ? t.createdAt : null,
      completedAt: typeof t.completedAt === "string" ? t.completedAt : null,
      recurrenceUnit: typeof t.recurrenceUnit === "string" ? t.recurrenceUnit : null,
      recurrenceInterval: typeof t.recurrenceInterval === "number" ? t.recurrenceInterval : null,
      recurrenceMissed: t.recurrenceMissed === "keepOneOpen" || t.recurrenceMissed === "startFresh" || t.recurrenceMissed === "keepEach"
        ? t.recurrenceMissed : null,
      recurrenceMissedFrom: typeof t.recurrenceMissedFrom === "string" ? t.recurrenceMissedFrom : null,
      recurrenceAfterCompletion: Boolean(t.recurrenceAfterCompletion),
      recurrencePaused: Boolean(t.recurrencePaused),
    }));

  const checklistItems: ChecklistItemRow[] = rawChecklists
    .filter((c) => typeof c.id === "string" && typeof c.taskId === "string" && typeof c.title === "string" && c.title.trim())
    .map((c) => ({
      id: String(c.id),
      taskId: String(c.taskId),
      title: String(c.title).trim(),
      checked: Boolean(c.checked),
      checkedAt: typeof c.checkedAt === "string" ? c.checkedAt : null,
      position: typeof c.position === "number" ? c.position : null,
    }));

  const taskRefs: TaskRefRow[] = rawRefs
    .filter((r) => typeof r.id === "string" && typeof r.taskId === "string" && typeof r.key === "string")
    .map((r) => ({
      id: String(r.id),
      taskId: String(r.taskId),
      key: String(r.key),
      role: typeof r.role === "string" ? r.role : "about",
      snapshot: r.snapshot && typeof r.snapshot === "object" ? (r.snapshot as TaskRefRow["snapshot"]) : null,
      position: typeof r.position === "number" ? r.position : null,
    }));

  // Count non-task top-level arrays (like legacy life-OS sections/entries) that will be skipped.
  const knownKeys = new Set([
    "version",
    "exportedAt",
    "areas",
    "projects",
    "tags",
    "tasks",
    "checklistItems",
    "checklists",
    "taskRefs",
    "refs",
  ]);
  let skippedNonTaskCount = 0;
  for (const [k, v] of Object.entries(obj)) {
    if (!knownKeys.has(k) && Array.isArray(v)) {
      skippedNonTaskCount += v.length;
    }
  }

  if (areas.length === 0 && projects.length === 0 && tasks.length === 0 && tags.length === 0) {
    throw new Error("No Septena areas, projects, or tasks were found in that file.");
  }

  return {
    areas,
    projects,
    tags,
    tasks,
    checklistItems,
    taskRefs,
    skippedNonTaskCount,
  };
}
