import type { Context } from "hono";
import pkg from "../package.json";
import type { Env } from "./env.js";

// Single source of truth for the server version — the MCP `serverInfo.version`
// must always match package.json so a deployed Worker maps to a tagged release.
const SERVER_VERSION = pkg.version;
import { CloudKitClient, CloudKitError } from "./cloudkit.js";
import { getCkTokenForAccessToken, touchAccessToken, putUserSections, getUserSections } from "./storage.js";
import { logEvent } from "./util.js";

// Throttle lastUsedAt writes: at most one KV write per token per interval.
const TOUCH_INTERVAL_MS = 5 * 60 * 1000;
import { listTasks, listTasksJsonSchema, type ListTasksInput } from "./tools/listTasks.js";
import { listProjects, listProjectsJsonSchema, type ListProjectsInput } from "./tools/listProjects.js";
import { listAreas, listAreasJsonSchema, type ListAreasInput } from "./tools/listAreas.js";
import { getSettings, getSettingsJsonSchema } from "./tools/getSettings.js";
import { listSections, listSectionsJsonSchema, type ListSectionsInput } from "./tools/listSections.js";
import {
  updateSettings,
  updateSettingsJsonSchema,
  type UpdateSettingsInput,
  updateSection,
  updateSectionJsonSchema,
  type UpdateSectionInput,
} from "./tools/writeSettings.js";
import {
  createTask, createTaskJsonSchema, type CreateTaskInput,
  completeTask, completeTaskJsonSchema,
  updateTask, updateTaskJsonSchema, type UpdateTaskInput,
  deferTask, deferTaskJsonSchema,
  moveToToday, moveToTodayJsonSchema,
  threadGet, threadGetJsonSchema,
  threadAppend, threadAppendJsonSchema,
  setAcceptance, setAcceptanceJsonSchema,
  setEndState, setEndStateJsonSchema,
  setAssignee, setAssigneeJsonSchema,
  pendingReasoning, pendingReasoningJsonSchema,
} from "./tools/writeTasks.js";
import {
  listGoals, listGoalsJsonSchema,
  createGoal, createGoalJsonSchema, type CreateGoalInput,
  updateGoal, updateGoalJsonSchema, type UpdateGoalInput,
  deleteGoal, deleteGoalJsonSchema,
} from "./tools/goals.js";
import {
  listHabits, listHabitsJsonSchema, type ListHabitsInput,
  createHabit, createHabitJsonSchema, type CreateHabitInput,
  updateHabit, updateHabitJsonSchema, type UpdateHabitInput,
  deleteHabit, deleteHabitJsonSchema,
  toggleHabit, toggleHabitJsonSchema, type ToggleHabitInput,
} from "./tools/habits.js";
import {
  listSupplements, listSupplementsJsonSchema, type ListSupplementsInput,
  createSupplement, createSupplementJsonSchema, type CreateSupplementInput,
  updateSupplement, updateSupplementJsonSchema, type UpdateSupplementInput,
  deleteSupplement, deleteSupplementJsonSchema,
  toggleSupplement, toggleSupplementJsonSchema, type ToggleSupplementInput,
} from "./tools/supplements.js";
import {
  listChores, listChoresJsonSchema,
  createChore, createChoreJsonSchema, type CreateChoreInput,
  updateChore, updateChoreJsonSchema, type UpdateChoreInput,
  deleteChore, deleteChoreJsonSchema,
  completeChore, completeChoreJsonSchema, type CompleteChoreInput,
  deferChore, deferChoreJsonSchema, type DeferChoreInput,
  uncompleteChore, uncompleteChoreJsonSchema, type UncompleteChoreInput,
} from "./tools/chores.js";
import {
  listCaffeineEvents, listCaffeineEventsJsonSchema, type ListCaffeineEventsInput,
  logCaffeineEvent, logCaffeineEventJsonSchema, type LogCaffeineEventInput,
  deleteCaffeineEvent, deleteCaffeineEventJsonSchema,
  listCaffeineBeans, listCaffeineBeansJsonSchema,
  createCaffeineBean, createCaffeineBeanJsonSchema, type CreateCaffeineBeanInput,
  deleteCaffeineBean, deleteCaffeineBeanJsonSchema,
} from "./tools/caffeine.js";
import {
  listCannabisEvents, listCannabisEventsJsonSchema, type ListCannabisEventsInput,
  logCannabisEvent, logCannabisEventJsonSchema, type LogCannabisEventInput,
  deleteCannabisEvent, deleteCannabisEventJsonSchema,
  listCannabisStrains, listCannabisStrainJsonSchema,
  createCannabisStrain, createCannabisStrainJsonSchema, type CreateCannabisStrainInput,
  deleteCannabisStrain, deleteCannabisStrainJsonSchema,
} from "./tools/cannabis.js";
import {
  listGutEvents, listGutEventsJsonSchema, type ListGutEventsInput,
  logGutEvent, logGutEventJsonSchema, type LogGutEventInput,
  deleteGutEvent, deleteGutEventJsonSchema,
} from "./tools/gut.js";
import {
  listNutritionEntries, listNutritionEntriesJsonSchema, type ListNutritionEntriesInput,
  logNutritionEntry, logNutritionEntryJsonSchema, type LogNutritionEntryInput,
  updateNutritionEntry, updateNutritionEntryJsonSchema, type UpdateNutritionEntryInput,
  deleteNutritionEntry, deleteNutritionEntryJsonSchema,
  getNutritionDaySummary, getNutritionDaySummaryJsonSchema, type GetNutritionDaySummaryInput,
} from "./tools/nutrition.js";
import {
  listTrainingEntries, listTrainingEntriesJsonSchema, type ListTrainingEntriesInput,
  logTrainingEntry, logTrainingEntryJsonSchema, type LogTrainingEntryInput,
  updateTrainingEntry, updateTrainingEntryJsonSchema, type UpdateTrainingEntryInput,
  deleteTrainingEntry, deleteTrainingEntryJsonSchema,
  retagTrainingSession, retagTrainingSessionJsonSchema, type RetagTrainingSessionInput,
  listExercises, listExercisesJsonSchema, type ListExercisesInput,
  createExercise, createExerciseJsonSchema, type CreateExerciseInput,
  updateExercise, updateExerciseJsonSchema, type UpdateExerciseInput,
  deleteExercise, deleteExerciseJsonSchema,
  listSessionTypes, listSessionTypesJsonSchema, type ListSessionTypesInput,
  createSessionType, createSessionTypeJsonSchema, type CreateSessionTypeInput,
  updateSessionType, updateSessionTypeJsonSchema, type UpdateSessionTypeInput,
  deleteSessionType, deleteSessionTypeJsonSchema,
} from "./tools/training.js";
import {
  logHydration, logHydrationJsonSchema, type LogHydrationInput,
  hydrationToday, hydrationTodayJsonSchema,
  hydrationHistory, hydrationHistoryJsonSchema, type HydrationHistoryInput,
} from "./tools/hydration.js";
import {
  listGroceryItems, listGroceryItemsJsonSchema, type ListGroceryItemsInput,
  createGroceryItem, createGroceryItemJsonSchema, type CreateGroceryItemInput,
  updateGroceryItem, updateGroceryItemJsonSchema, type UpdateGroceryItemInput,
  setGroceryLow, setGroceryLowJsonSchema, type SetGroceryLowInput,
  deleteGroceryItem, deleteGroceryItemJsonSchema,
  listGroceryCategories, listGroceryCategoriesJsonSchema, type ListGroceryCategoriesInput,
  createGroceryCategory, createGroceryCategoryJsonSchema, type CreateGroceryCategoryInput,
  deleteGroceryCategory, deleteGroceryCategoryJsonSchema,
} from "./tools/grocery.js";

// Hand-rolled MCP JSON-RPC over HTTP. The full Streamable HTTP transport
// adds SSE for server-initiated messages; we don't need that yet — every
// tool we expose is request/response.
//
// claude.ai (and other MCP clients) send POST /mcp with a JSON-RPC envelope:
//   { "jsonrpc": "2.0", "id": ..., "method": "tools/list" | "tools/call", ... }
// We dispatch and return a JSON-RPC response.

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number | string | null;
  method: string;
  params?: Record<string, unknown>;
}

type Tool = { name: string; description: string; inputSchema: unknown };

// Always exposed regardless of section configuration.
const GLOBAL_TOOLS: Tool[] = [
  {
    name: "tasks_list",
    description:
      "List Septena tasks for a given view (today, inbox, upcoming, anytime, someday, completed).",
    inputSchema: listTasksJsonSchema,
  },
  {
    name: "tasks_list_projects",
    description: "List Septena projects available for task assignment, optionally filtered by status.",
    inputSchema: listProjectsJsonSchema,
  },
  {
    name: "tasks_list_areas",
    description: "List Septena areas available for task assignment (top-level containers like 'home', 'envisioning').",
    inputSchema: listAreasJsonSchema,
  },
  {
    name: "tasks_create",
    description: "Create a new Septena task. Returns the new id.",
    inputSchema: createTaskJsonSchema,
  },
  {
    name: "tasks_complete",
    description: "Mark a task done. Errors on recurring tasks (complete those in the app so the next occurrence spawns).",
    inputSchema: completeTaskJsonSchema,
  },
  {
    name: "tasks_update",
    description: "Update fields on an existing task. Any subset of title, today, scheduled, due, area, project, status (cancelled).",
    inputSchema: updateTaskJsonSchema,
  },
  {
    name: "tasks_defer",
    description: "Defer a task to a future date (sets scheduled, clears today).",
    inputSchema: deferTaskJsonSchema,
  },
  {
    name: "tasks_move_to_today",
    description: "Pin a task to Today (sets today=true, clears scheduled).",
    inputSchema: moveToTodayJsonSchema,
  },
  {
    name: "tasks_thread_get",
    description: "Read a task's conversation (TaskConvo: confirmedIntent, acceptance, thread of turns, artifact, handoff, endState, assignee).",
    inputSchema: threadGetJsonSchema,
  },
  {
    name: "tasks_thread_append",
    description: "Append one turn to a task's conversation. Provider turns propose (question+options); user turns choose (chosen+inReplyTo). A confirm-step turn carrying a chosen also sets confirmedIntent — put the resolved intent sentence in note.",
    inputSchema: threadAppendJsonSchema,
  },
  {
    name: "tasks_set_acceptance",
    description: "Set the agent-done bar (what 'done' means for the agent's deliverable). Distinct from task completion, which is the human's bar.",
    inputSchema: setAcceptanceJsonSchema,
  },
  {
    name: "tasks_set_endstate",
    description: "Record the conversation's terminal end-state.",
    inputSchema: setEndStateJsonSchema,
  },
  {
    name: "tasks_set_assignee",
    description: "Route a task: me | local | claude, or null to let the router decide. Setting claude marks it for the reasoning queue.",
    inputSchema: setAssigneeJsonSchema,
  },
  {
    name: "tasks_pending_reasoning",
    description: "List tasks awaiting reasoning: marked for Claude, or whose last provider turn was low-confidence, and not yet terminal.",
    inputSchema: pendingReasoningJsonSchema,
  },
  {
    name: "goals_list",
    description: "List Septena goals (free-text intentions tagged with section keys).",
    inputSchema: listGoalsJsonSchema,
  },
  {
    name: "goals_create",
    description: "Create a new Septena goal. Optionally tag with section keys.",
    inputSchema: createGoalJsonSchema,
  },
  {
    name: "goals_update",
    description: "Update a goal's text and/or section tags. sections replaces the existing tags entirely.",
    inputSchema: updateGoalJsonSchema,
  },
  {
    name: "settings_get",
    description: "Read Septena app settings from CloudKit.",
    inputSchema: getSettingsJsonSchema,
  },
  {
    name: "sections_list",
    description: "List Septena section config from CloudKit, ordered by settings.section_order when present.",
    inputSchema: listSectionsJsonSchema,
  },
  {
    name: "settings_update",
    description: "Patch Septena app settings in CloudKit. section_order is canonicalized; sections metadata must be updated with sections_update.",
    inputSchema: updateSettingsJsonSchema,
  },
  {
    name: "sections_update",
    description: "Create or update one Septena section record in CloudKit. Supports label, color, and optional order index.",
    inputSchema: updateSectionJsonSchema,
  },
];

// Exposed only when the matching key appears in settings.section_order.
// Keys must match the canonical section keys stored in CloudKit (see SECTION_KEY_ALIASES in writeSettings.ts).
// A section's tools are exposed only when its key is both enabled and present
// in the filtered list; when that list is empty, only GLOBAL_TOOLS are shown.
const SECTION_TOOLS: Record<string, Tool[]> = {
  habits: [
    {
      name: "habits_list",
      description: "List habit definitions with done/skipped state for a given date (defaults to today).",
      inputSchema: listHabitsJsonSchema,
    },
    {
      name: "habits_create",
      description: "Create a new habit definition.",
      inputSchema: createHabitJsonSchema,
    },
    {
      name: "habits_toggle",
      description: "Mark a habit done or skipped for a date. Pass done=false and skipped=false to unmark.",
      inputSchema: toggleHabitJsonSchema,
    },
  ],
  supplements: [
    {
      name: "supplements_list",
      description: "List supplement definitions with done state for a given date (defaults to today).",
      inputSchema: listSupplementsJsonSchema,
    },
    {
      name: "supplements_create",
      description: "Create a new supplement definition.",
      inputSchema: createSupplementJsonSchema,
    },
    {
      name: "supplements_toggle",
      description: "Mark a supplement taken (done=true) or untaken (done=false) for a date.",
      inputSchema: toggleSupplementJsonSchema,
    },
  ],
  chores: [
    {
      name: "chores_list",
      description: "List chore definitions with computed due dates and last-completed dates (replays 180 days of events).",
      inputSchema: listChoresJsonSchema,
    },
    {
      name: "chores_create",
      description: "Create a new chore definition.",
      inputSchema: createChoreJsonSchema,
    },
    {
      name: "chores_complete",
      description: "Mark a chore as completed for today (or a given date).",
      inputSchema: completeChoreJsonSchema,
    },
    {
      name: "chores_uncomplete",
      description: "Remove the most recent completion event for a chore on a given date.",
      inputSchema: uncompleteChoreJsonSchema,
    },
  ],
  caffeine: [
    {
      name: "caffeine_events_list",
      description: "List caffeine intake events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
      inputSchema: listCaffeineEventsJsonSchema,
    },
    {
      name: "caffeine_event_log",
      description: "Log a new caffeine intake event (v60, matcha, or other).",
      inputSchema: logCaffeineEventJsonSchema,
    },
  ],
  cannabis: [
    {
      name: "cannabis_events_list",
      description: "List cannabis intake events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
      inputSchema: listCannabisEventsJsonSchema,
    },
    {
      name: "cannabis_event_log",
      description: "Log a new cannabis intake event (vape or edible).",
      inputSchema: logCannabisEventJsonSchema,
    },
  ],
  gut: [
    {
      name: "gut_events_list",
      description: "List gut/digestive events. Defaults to last 7 days; pass date for a single day or from/to for a range.",
      inputSchema: listGutEventsJsonSchema,
    },
    {
      name: "gut_event_log",
      description: "Log a new gut event with Bristol Stool Scale type and optional discomfort details.",
      inputSchema: logGutEventJsonSchema,
    },
  ],
  nutrition: [
    {
      name: "nutrition_entries_list",
      description: "List nutrition (meal/food) entries. Defaults to last 7 days; pass date for a single day or from/to for a range. Each entry includes loggedAt, foods (newline-separated), macros (proteinG/fatG/carbsG), and optional micros.",
      inputSchema: listNutritionEntriesJsonSchema,
    },
    {
      name: "nutrition_entry_log",
      description: "Log a new meal / food entry. Required: foods (newline-separated list). Macros default to 0 if omitted; kcal is computed from 4P+9F+4C+7A unless overridden. Source is auto-tagged 'mcp' for provenance when the field is available.",
      inputSchema: logNutritionEntryJsonSchema,
    },
    {
      name: "nutrition_entry_update",
      description: "Update fields on an existing nutrition entry. Any subset of foods, loggedAt, mealType, macros, or micros.",
      inputSchema: updateNutritionEntryJsonSchema,
    },
    {
      name: "nutrition_day_summary",
      description: "Read the computed daily nutrition summary (totals across all meals) for a date. Read-only — the app computes summaries automatically from entries.",
      inputSchema: getNutritionDaySummaryJsonSchema,
    },
  ],
  training: [
    {
      name: "training_entries_list",
      description: "List exercise entries. Defaults to last 14 days; pass date for a single day, from/to for a range, or exercise to filter.",
      inputSchema: listTrainingEntriesJsonSchema,
    },
    {
      name: "training_entry_log",
      description: "Log a new exercise set / entry. Required: sessionType (e.g. 'upper'), exercise (canonical name). Provide weight/sets/reps for strength; durationMin/distanceM for cardio.",
      inputSchema: logTrainingEntryJsonSchema,
    },
    {
      name: "training_entry_update",
      description: "Update fields on an existing exercise entry.",
      inputSchema: updateTrainingEntryJsonSchema,
    },
    {
      name: "training_exercises_list",
      description: "List exercise catalog (definitions). Filter by type (strength|cardio|mobility|core) or archived state.",
      inputSchema: listExercisesJsonSchema,
    },
  ],
  hydration: [
    {
      name: "hydration_log",
      description: "Log water intake in ml. Backed by Nutrition — writes a water-only NutritionEntry (foods=Water, all macros zero) so the day's nutrition summary sees it. Use this rather than nutrition_entry_log for plain water.",
      inputSchema: logHydrationJsonSchema,
    },
    {
      name: "hydration_today",
      description: "Today's total water ml + the list of water-only entries. Total INCLUDES water recorded on real meal entries, so it matches the iOS Hydration view.",
      inputSchema: hydrationTodayJsonSchema,
    },
    {
      name: "hydration_history",
      description: "Per-day water totals over a range. Defaults to last 7 days. Each day's total sums waterMl across all nutrition entries (water-only + meal-attached).",
      inputSchema: hydrationHistoryJsonSchema,
    },
  ],
  groceries: [
    {
      name: "grocery_items_list",
      description: "List grocery items. Filter by low (running-low flag) or category (id).",
      inputSchema: listGroceryItemsJsonSchema,
    },
    {
      name: "grocery_item_create",
      description: "Add a new grocery item. category is an optional GroceryCategory id.",
      inputSchema: createGroceryItemJsonSchema,
    },
    {
      name: "grocery_item_set_low",
      description: "Mark a grocery item as low/restocked. low=true means out/running low; low=false clears the flag and stamps lastBought=today.",
      inputSchema: setGroceryLowJsonSchema,
    },
  ],
};

function buildToolList(sectionOrder: string[] | null): Tool[] {
  // Globals are always exposed. Section tools are opt-in: a section's tools
  // appear ONLY when its key is in the (enabled-gated) list. null/empty →
  // globals only, never the full set. We never expose every section's tools
  // as a fallback — that would leak tools for sections the user disabled.
  const keys = sectionOrder ?? [];
  const sectionTools = keys.flatMap(key => SECTION_TOOLS[key] ?? []);
  return [...GLOBAL_TOOLS, ...sectionTools];
}

export async function mcpHandler(c: Context<{ Bindings: Env }>) {
  const auth = c.req.header("Authorization") ?? "";
  const m = auth.match(/^Bearer\s+(.+)$/);
  if (!m) return unauthorized("missing Bearer header");
  const accessToken = m[1];

  const tokenRec = await getCkTokenForAccessToken(c.env, accessToken);
  if (!tokenRec) return unauthorized("access_token not found in KV");
  const { ckWebAuthToken, createdAt, lastUsedAt, userRecordName } = tokenRec;

  // Bump lastUsedAt (throttled, non-blocking) so the cleanup cron can tell
  // this token is alive. One KV write per TOUCH_INTERVAL_MS at most.
  if (Date.now() - lastUsedAt > TOUCH_INTERVAL_MS) {
    c.executionCtx.waitUntil(touchAccessToken(c.env, accessToken));
  }

  const req = (await c.req.json().catch(() => null)) as JsonRpcRequest | null;
  if (!req || req.jsonrpc !== "2.0" || !req.method) {
    return rpcError(req?.id ?? null, -32600, "Invalid Request");
  }

  // JSON-RPC notifications carry no id; per spec the server must not reply.
  // MCP clients send notifications/initialized after the handshake — answer
  // with a bare 202 instead of a "Method not found" error.
  if (req.id === undefined || req.id === null || req.method.startsWith("notifications/")) {
    return new Response(null, { status: 202 });
  }

  const client = new CloudKitClient(c.env, ckWebAuthToken);

  try {
    switch (req.method) {
      case "initialize": {
        // Echo the client's requested protocol version when present so we
        // stay forward-compatible as the MCP spec advances.
        const requested = (req.params as { protocolVersion?: unknown } | undefined)?.protocolVersion;
        const protocolVersion = typeof requested === "string" ? requested : "2024-11-05";
        return rpcResult(req.id, {
          protocolVersion,
          capabilities: { tools: {} },
          serverInfo: { name: "septena-mcp-gateway", version: SERVER_VERSION },
        });
      }
      case "ping":
        // Liveness/health probe — must be a fast empty result and never
        // touches CloudKit, or clients may judge the connector unhealthy.
        return rpcResult(req.id, {});
      case "tools/list": {
        // Source of truth for "which sections this user has enabled" is
        // the per-section `Section.isEnabled` flag the iOS app writes.
        // We still consult `settings.section_order` for ordering, but
        // a section being present in section_order is no longer
        // sufficient — it has to be enabled too. Section records from
        // pre-isEnabled builds default to true so legacy users see all
        // their tools.
        let filtered: string[] | null = null;
        let sectionCount = 0;
        let enabledKeys = new Set<string>();
        try {
          const [{ sections }, { settings }] = await Promise.all([
            listSections(client, {}),
            getSettings(client),
          ]);
          sectionCount = sections.length;
          enabledKeys = new Set(sections.filter(s => s.isEnabled).map(s => s.key));
          const order = Array.isArray(settings.section_order)
            ? (settings.section_order as unknown[]).filter((v): v is string => typeof v === "string")
            : [];
          // Order-aware filter: only keys both ordered and enabled. If no
          // sections exist yet (brand-new user before iOS seeds), [] →
          // buildToolList exposes globals only, never every section's tools.
          filtered = sections.length === 0
            ? []
            : order.length > 0
              ? order.filter(k => enabledKeys.has(k))
              : Array.from(enabledKeys);
          // Cache the freshly-computed manifest so a later auth-expired
          // tools/list can serve it instead of hard-401'ing (see catch).
          if (userRecordName) {
            c.executionCtx.waitUntil(putUserSections(c.env, userRecordName, filtered));
          }
        } catch (err) {
          if (err instanceof CloudKitError && err.isAuthExpired) {
            // Auth expiry during tools/list. Re-throwing → hard 401 → claude.ai
            // flips the connector to a *sticky* disconnected state that only a
            // manual reconnect clears (the daily-disconnect symptom). When the
            // bearer is identity-bound the lapse is transient — the app re-mints
            // the user's token on foreground — so keep the connector alive by
            // serving the last-known section manifest from cache (globals-only
            // if we have none). The next tools/list after the push refreshes it.
            if (userRecordName) {
              const cached = await getUserSections(c.env, userRecordName);
              logEvent("tools_list_auth_expired_degraded", {
                cached: cached !== null,
                count: cached?.length ?? 0,
              });
              filtered = cached ?? [];
            } else {
              // Legacy bootstrap-only bearer: no identity to self-heal through,
              // so the spec-correct discovery 401 (re-run OAuth) is the only fix.
              throw err;
            }
          } else {
            // Any other CloudKit hiccup: degrade to globals only. Still a
            // non-empty manifest (so the connector doesn't look dead), but we
            // never leak section tools when we can't confirm what's enabled.
            logEvent("tools_list_degraded", {
              error: err instanceof Error ? err.message : String(err),
            });
            filtered = [];
          }
        }
        const tools = buildToolList(filtered);
        // Tool count + names per request: a partial manifest (e.g. task
        // tools present, nutrition absent) shows up here directly.
        logEvent("tools_list", {
          count: tools.length,
          sectionCount,
          enabled: Array.from(enabledKeys),
          names: tools.map(t => t.name),
        });
        return rpcResult(req.id, { tools });
      }
      case "tools/call": {
        const params = (req.params ?? {}) as {
          name?: string;
          arguments?: Record<string, unknown>;
        };
        const startedAt = Date.now();
        try {
          const res = await callTool(client, req.id, params);
          logEvent("tool_call", { name: params.name ?? "?", ok: true, ms: Date.now() - startedAt });
          return res;
        } catch (err) {
          logEvent("tool_call", {
            name: params.name ?? "?",
            ok: false,
            ms: Date.now() - startedAt,
            status: err instanceof CloudKitError ? err.status : undefined,
            error: err instanceof Error ? err.message.slice(0, 200) : String(err),
          });
          throw err; // outer catch classifies auth-expiry vs generic error
        }
      }
      default:
        return rpcError(req.id, -32601, `Method not found: ${req.method}`);
    }
  } catch (err) {
    if (err instanceof CloudKitError && err.isAuthExpired) {
      // This is the lapse event: the ckWebAuthToken behind the access
      // token has expired. tokenAgeSeconds is the lifetime we care about
      // (T1−T0) — logged directly so no manual diffing of two log lines.
      // ~1800 ⇒ 30-min default token; ~1.2M ⇒ 2-week "keep me signed in".
      const tokenAgeSeconds = Math.round((Date.now() - createdAt) / 1000);
      logEvent("ck_auth_expired", {
        method: req.method,
        status: err.status,
        tokenAgeSeconds,
        tokenAgeMinutes: Math.round(tokenAgeSeconds / 60),
        // ORIGIN signal: the raw CloudKit response. Distinguishes a genuine
        // auth expiry (AUTHENTICATION_REQUIRED/FAILED) from a transient 421
        // Misdirected we may be misclassifying as expiry.
        ckBody: err.body.slice(0, 300),
        // Which recovery path we took: in-band (bearer is user-bound, the app
        // can re-mint → keep the connector connected) vs hard 401 (legacy
        // bootstrap-only bearer → client must re-run OAuth).
        recovery: userRecordName && req.method === "tools/call" ? "inband" : "401",
      });
      // Self-heal: when the bearer is bound to a CloudKit identity, the
      // expiry is transient — the Septena app re-mints the user's token (on
      // foreground, or from the "Keep Claude connected" nudge) and the gateway
      // resolves every request to that freshest token. So instead of a hard
      // 401 — which flips Claude's connector to a *sticky* disconnected state
      // that only a manual claude.ai reconnect clears — return an in-band tool
      // error. The connector stays connected; the very next tool call after
      // the app pushes a fresh token just works, no reconnect needed.
      if (userRecordName && req.method === "tools/call") {
        return rpcResult(req.id, {
          isError: true,
          content: [{ type: "text", text: AUTH_EXPIRED_MESSAGE }],
        });
      }
      // Legacy bootstrap-only bearer (no identity binding): the only recovery
      // is an OAuth re-run, so emit the spec-correct discovery 401.
      return unauthorized(`CloudKit auth expired (status=${err.status})`);
    }
    // Non-auth CloudKit failure — capture status + body so a transient error
    // that should NOT disconnect (but currently surfaces as -32603) is visible.
    if (err instanceof CloudKitError) {
      logEvent("cloudkit_error", { method: req.method, status: err.status, ckBody: err.body.slice(0, 300) });
    }
    const msg = err instanceof Error ? err.message : String(err);
    return rpcError(req.id, -32603, msg);
  }
}

async function callTool(
  client: CloudKitClient,
  id: JsonRpcRequest["id"],
  params: { name?: string; arguments?: Record<string, unknown> },
): Promise<Response> {

  switch (params.name) {
    case "tasks_list": {
      const result = await listTasks(client, (params.arguments ?? {}) as ListTasksInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_list_projects": {
      const result = await listProjects(client, (params.arguments ?? {}) as ListProjectsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_list_areas": {
      const result = await listAreas(client, (params.arguments ?? {}) as ListAreasInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "settings_get": {
      const result = await getSettings(client);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "sections_list": {
      const result = await listSections(client, (params.arguments ?? {}) as ListSectionsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "settings_update": {
      const result = await updateSettings(client, (params.arguments ?? {}) as unknown as UpdateSettingsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "sections_update": {
      const result = await updateSection(client, (params.arguments ?? {}) as unknown as UpdateSectionInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_create": {
      const result = await createTask(client, (params.arguments ?? {}) as unknown as CreateTaskInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_complete": {
      const result = await completeTask(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_update": {
      const result = await updateTask(client, (params.arguments ?? {}) as unknown as UpdateTaskInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_defer": {
      const result = await deferTask(client, (params.arguments ?? {}) as unknown as { id: string; until: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_move_to_today": {
      const result = await moveToToday(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_thread_get": {
      const result = await threadGet(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_thread_append": {
      const result = await threadAppend(client, (params.arguments ?? {}) as unknown as Parameters<typeof threadAppend>[1]);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_set_acceptance": {
      const result = await setAcceptance(client, (params.arguments ?? {}) as unknown as { id: string; acceptance: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_set_endstate": {
      const result = await setEndState(client, (params.arguments ?? {}) as unknown as { id: string; endState: string; note?: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_set_assignee": {
      const result = await setAssignee(client, (params.arguments ?? {}) as unknown as { id: string; assignee: "me" | "local" | "claude" | null });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "tasks_pending_reasoning": {
      const result = await pendingReasoning(client, (params.arguments ?? {}) as unknown as { limit?: number });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "goals_list": {
      const result = await listGoals(client);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "goals_create": {
      const result = await createGoal(client, (params.arguments ?? {}) as unknown as CreateGoalInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "goals_update": {
      const result = await updateGoal(client, (params.arguments ?? {}) as unknown as UpdateGoalInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "goals_delete": {
      const result = await deleteGoal(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "habits_list": {
      const result = await listHabits(client, (params.arguments ?? {}) as ListHabitsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "habits_create": {
      const result = await createHabit(client, (params.arguments ?? {}) as unknown as CreateHabitInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "habits_update": {
      const result = await updateHabit(client, (params.arguments ?? {}) as unknown as UpdateHabitInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "habits_delete": {
      const result = await deleteHabit(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "habits_toggle": {
      const result = await toggleHabit(client, (params.arguments ?? {}) as unknown as ToggleHabitInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "supplements_list": {
      const result = await listSupplements(client, (params.arguments ?? {}) as ListSupplementsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "supplements_create": {
      const result = await createSupplement(client, (params.arguments ?? {}) as unknown as CreateSupplementInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "supplements_update": {
      const result = await updateSupplement(client, (params.arguments ?? {}) as unknown as UpdateSupplementInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "supplements_delete": {
      const result = await deleteSupplement(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "supplements_toggle": {
      const result = await toggleSupplement(client, (params.arguments ?? {}) as unknown as ToggleSupplementInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "chores_list": {
      const result = await listChores(client);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "chores_create": {
      const result = await createChore(client, (params.arguments ?? {}) as unknown as CreateChoreInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "chores_update": {
      const result = await updateChore(client, (params.arguments ?? {}) as unknown as UpdateChoreInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "chores_delete": {
      const result = await deleteChore(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "chores_complete": {
      const result = await completeChore(client, (params.arguments ?? {}) as unknown as CompleteChoreInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "chores_defer": {
      const result = await deferChore(client, (params.arguments ?? {}) as unknown as DeferChoreInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "chores_uncomplete": {
      const result = await uncompleteChore(client, (params.arguments ?? {}) as unknown as UncompleteChoreInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    // ---- Caffeine ----
    case "caffeine_events_list": {
      const result = await listCaffeineEvents(client, (params.arguments ?? {}) as ListCaffeineEventsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "caffeine_event_log": {
      const result = await logCaffeineEvent(client, (params.arguments ?? {}) as unknown as LogCaffeineEventInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "caffeine_event_delete": {
      const result = await deleteCaffeineEvent(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "caffeine_beans_list": {
      const result = await listCaffeineBeans(client);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "caffeine_bean_create": {
      const result = await createCaffeineBean(client, (params.arguments ?? {}) as unknown as CreateCaffeineBeanInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "caffeine_bean_delete": {
      const result = await deleteCaffeineBean(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    // ---- Cannabis ----
    case "cannabis_events_list": {
      const result = await listCannabisEvents(client, (params.arguments ?? {}) as ListCannabisEventsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "cannabis_event_log": {
      const result = await logCannabisEvent(client, (params.arguments ?? {}) as unknown as LogCannabisEventInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "cannabis_event_delete": {
      const result = await deleteCannabisEvent(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "cannabis_strains_list": {
      const result = await listCannabisStrains(client);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "cannabis_strain_create": {
      const result = await createCannabisStrain(client, (params.arguments ?? {}) as unknown as CreateCannabisStrainInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "cannabis_strain_delete": {
      const result = await deleteCannabisStrain(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    // ---- Gut ----
    case "gut_events_list": {
      const result = await listGutEvents(client, (params.arguments ?? {}) as ListGutEventsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "gut_event_log": {
      const result = await logGutEvent(client, (params.arguments ?? {}) as unknown as LogGutEventInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "gut_event_delete": {
      const result = await deleteGutEvent(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    // ---- Nutrition ----
    case "nutrition_entries_list": {
      const result = await listNutritionEntries(client, (params.arguments ?? {}) as ListNutritionEntriesInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "nutrition_entry_log": {
      const result = await logNutritionEntry(client, (params.arguments ?? {}) as unknown as LogNutritionEntryInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "nutrition_entry_update": {
      const result = await updateNutritionEntry(client, (params.arguments ?? {}) as unknown as UpdateNutritionEntryInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "nutrition_entry_delete": {
      const result = await deleteNutritionEntry(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "nutrition_day_summary": {
      const result = await getNutritionDaySummary(client, (params.arguments ?? {}) as GetNutritionDaySummaryInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    // ---- Training ----
    case "training_entries_list": {
      const result = await listTrainingEntries(client, (params.arguments ?? {}) as ListTrainingEntriesInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_entry_log": {
      const result = await logTrainingEntry(client, (params.arguments ?? {}) as unknown as LogTrainingEntryInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_entry_update": {
      const result = await updateTrainingEntry(client, (params.arguments ?? {}) as unknown as UpdateTrainingEntryInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_entry_delete": {
      const result = await deleteTrainingEntry(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_session_retag": {
      const result = await retagTrainingSession(client, (params.arguments ?? {}) as unknown as RetagTrainingSessionInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_exercises_list": {
      const result = await listExercises(client, (params.arguments ?? {}) as ListExercisesInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_exercise_create": {
      const result = await createExercise(client, (params.arguments ?? {}) as unknown as CreateExerciseInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_exercise_update": {
      const result = await updateExercise(client, (params.arguments ?? {}) as unknown as UpdateExerciseInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_exercise_delete": {
      const result = await deleteExercise(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_sessions_list": {
      const result = await listSessionTypes(client, (params.arguments ?? {}) as ListSessionTypesInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_session_create": {
      const result = await createSessionType(client, (params.arguments ?? {}) as unknown as CreateSessionTypeInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_session_update": {
      const result = await updateSessionType(client, (params.arguments ?? {}) as unknown as UpdateSessionTypeInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "training_session_delete": {
      const result = await deleteSessionType(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    // ---- Hydration ----
    case "hydration_log": {
      const result = await logHydration(client, (params.arguments ?? {}) as unknown as LogHydrationInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "hydration_today": {
      const result = await hydrationToday(client);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "hydration_history": {
      const result = await hydrationHistory(client, (params.arguments ?? {}) as HydrationHistoryInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    // ---- Groceries ----
    case "grocery_items_list": {
      const result = await listGroceryItems(client, (params.arguments ?? {}) as ListGroceryItemsInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "grocery_item_create": {
      const result = await createGroceryItem(client, (params.arguments ?? {}) as unknown as CreateGroceryItemInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "grocery_item_update": {
      const result = await updateGroceryItem(client, (params.arguments ?? {}) as unknown as UpdateGroceryItemInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "grocery_item_set_low": {
      const result = await setGroceryLow(client, (params.arguments ?? {}) as unknown as SetGroceryLowInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "grocery_item_delete": {
      const result = await deleteGroceryItem(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "grocery_categories_list": {
      const result = await listGroceryCategories(client, (params.arguments ?? {}) as ListGroceryCategoriesInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "grocery_category_create": {
      const result = await createGroceryCategory(client, (params.arguments ?? {}) as unknown as CreateGroceryCategoryInput);
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    case "grocery_category_delete": {
      const result = await deleteGroceryCategory(client, (params.arguments ?? {}) as unknown as { id: string });
      return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] });
    }
    default:
      return rpcError(id, -32602, `Unknown tool: ${params.name}`);
  }
}

// Returned in-band (as a tool result, not a transport 401) when a user-bound
// bearer's CloudKit token has lapsed. Addressed to the model so it relays
// clearly: the fix is on the user's device, and it heals without reconnecting
// this connector.
const AUTH_EXPIRED_MESSAGE =
  "Your Septena session has expired. Septena's access to your private iCloud " +
  "data uses a token that lasts about 8 hours and has to be refreshed from your " +
  "device. To restore access: open the Septena app on your iPhone or Mac (it " +
  "re-mints the token automatically on launch, or tap the “Reconnect” prompt). " +
  "Once you've done that, just ask again — this connector stays connected, so " +
  "I'll be able to read and write your data again with no need to reconnect from " +
  "claude.ai.";

function rpcResult(id: JsonRpcRequest["id"], result: unknown): Response {
  return Response.json({ jsonrpc: "2.0", id, result });
}

function rpcError(id: JsonRpcRequest["id"], code: number, message: string): Response {
  return Response.json({ jsonrpc: "2.0", id, error: { code, message } });
}

function unauthorized(reason?: string): Response {
  // RFC 9728 / MCP 2025-06: the `resource_metadata` parameter points clients
  // at our /.well-known/oauth-protected-resource doc, from which they learn
  // the authorization server. Without it, Claude's MCP client cannot
  // discover where to re-run OAuth on a 401 and falls back to "user must
  // reconnect manually" — the daily-disconnect symptom we're fixing.
  const resourceMetadata = "https://mcp.septena.app/.well-known/oauth-protected-resource";
  const params = [
    'Bearer realm="septena-mcp"',
    'error="invalid_token"',
    `resource_metadata="${resourceMetadata}"`,
  ];
  if (reason) logEvent("unauthorized", { reason });
  return new Response("Unauthorized", {
    status: 401,
    headers: { "WWW-Authenticate": params.join(", ") },
  });
}
