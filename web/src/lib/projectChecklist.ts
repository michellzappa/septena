// Checklist projects (docs/PROJECT_CHECKLIST_SPEC.md, #860). A Checklist is a
// regular project; these helpers only call the shared core and read the
// registry copy. The project list, rows and add field stay the standard ones.

import { callCore, isCoreReady } from "./core";
import { SURFACES_CATALOG, registryText } from "./generated/registries";
import type { ProjectRow, TaskRow } from "./types";

export const CHECKLIST_CHECKED = "checklistChecked";

export interface ChecklistLayout {
  ungrouped: string[];
  groups: { id: string; items: string[] }[];
  checked: string[];
  matches: string[];
  suggestedGroup: string | null;
}

/** True for a project the user uses as a Checklist. A legacy `groceries` value counts too. */
export function isChecklistProject(project: ProjectRow | null | undefined): boolean {
  return Boolean(project && !project.deletedAt && project.checklistMode);
}

/**
 * The core layout of one Checklist project. `rows` are the project's rows
 * (headings included) in project order. Grocery grouping applies to every
 * Checklist (#860 decision 2). Null before the core is ready.
 */
export function checklistLayout(rows: TaskRow[], query: string): ChecklistLayout | null {
  if (!isCoreReady()) return null;
  return callCore<ChecklistLayout>("projectChecklist", { rows, query, groceries: true });
}

/** The registry title of a core group key, or null for an unknown key. */
export function checklistGroupTitle(key: string, lang: string): string | null {
  const groups = SURFACES_CATALOG.checklistProjects.groups as Record<string, string>;
  return groups[key] ? registryText(groups[key], lang) : null;
}

/**
 * The heading a new item joins when the user adds it with no heading open:
 * the core's suggested group, with one stable heading per project. Returns
 * the heading id to use (null: ungrouped) and the heading to create first.
 * `projectRows` include deleted rows, so a heading the user deleted is not
 * created again.
 */
export function suggestedChecklistHeading(
  projectId: string,
  title: string,
  projectRows: TaskRow[],
  lang: string,
): { heading: string | null; create: { id: string; title: string } | null } {
  const none = { heading: null, create: null };
  const group = checklistLayout([], title)?.suggestedGroup;
  const groupTitle = group ? checklistGroupTitle(group, lang) : null;
  if (!group || !groupTitle) return none;
  const decision = callCore<{ heading: string | null; create: boolean }>("checklistHeading", {
    projectId,
    group,
    title: groupTitle,
    rows: projectRows,
  });
  if (!decision.heading) return none;
  return { heading: decision.heading, create: decision.create ? { id: decision.heading, title: groupTitle } : null };
}
