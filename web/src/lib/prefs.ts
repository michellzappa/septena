// Device-local UI preferences keyed identically to registry/settings.json storageKey values.

export interface WebDisplayPrefs {
  appearanceMode: "system" | "light" | "dark";
  textSizeStep: number;
  language: string;
  todayGroupByList: boolean;
  todayShowCompleted: boolean;
  reviewFadedExpanded: boolean;
  reviewTrackedExpanded: boolean;
  tasksShowFaded: boolean;
  sidebarCounts: boolean;
  loggingAnimationsEnabled: boolean;
  aiMode: "onDeviceOnly" | "auto" | "useMyClaude";
}

export const DEFAULT_WEB_PREFS: WebDisplayPrefs = {
  appearanceMode: "system",
  textSizeStep: 0,
  language: "en",
  todayGroupByList: true,
  todayShowCompleted: true,
  reviewFadedExpanded: false,
  reviewTrackedExpanded: false,
  tasksShowFaded: true,
  sidebarCounts: true,
  loggingAnimationsEnabled: true,
  aiMode: "auto",
};

const KEYS = {
  appearanceMode: "septena.appearance.mode",
  textSizeStep: "septena.display.textSizeStep",
  language: "septena.web.language",
  todayGroupByList: "septena.today.groupByList",
  todayShowCompleted: "septena.today.showCompleted",
  reviewFadedExpanded: "septena.web.reviewFadedExpanded",
  reviewTrackedExpanded: "septena.web.reviewTrackedExpanded",
  tasksShowFaded: "septena.tasks.showFaded",
  sidebarCounts: "septena.septask.sidebarCounts",
  loggingAnimationsEnabled: "septena.ui.loggingAnimations",
  aiMode: "septena.ai.mode",
} as const;

function readBool(key: string, fallback: boolean): boolean {
  try {
    const v = localStorage.getItem(key);
    if (v === "true") return true;
    if (v === "false") return false;
  } catch {
    // Ignore storage access errors.
  }
  return fallback;
}

export function loadWebPrefs(): WebDisplayPrefs {
  if (typeof window === "undefined") return DEFAULT_WEB_PREFS;
  try {
    const mode =
      localStorage.getItem(KEYS.appearanceMode) ??
      localStorage.getItem("septena.web.appearanceMode");
    const stepRaw =
      localStorage.getItem(KEYS.textSizeStep) ??
      localStorage.getItem("septena.web.textScaleStep");
    const step = Number(stepRaw);
    const lang = localStorage.getItem(KEYS.language) ?? "en";
    const ai = localStorage.getItem(KEYS.aiMode);
    return {
      appearanceMode: mode === "light" || mode === "dark" || mode === "system" ? mode : "system",
      textSizeStep: Number.isInteger(step) && step >= -2 && step <= 2 ? step : 0,
      language: lang,
      todayGroupByList: readBool(KEYS.todayGroupByList, true),
      todayShowCompleted: readBool(KEYS.todayShowCompleted, true),
      reviewFadedExpanded: readBool(KEYS.reviewFadedExpanded, false),
      reviewTrackedExpanded: readBool(KEYS.reviewTrackedExpanded, false),
      tasksShowFaded: readBool(KEYS.tasksShowFaded, true),
      sidebarCounts: readBool(KEYS.sidebarCounts, true),
      loggingAnimationsEnabled: readBool(KEYS.loggingAnimationsEnabled, true),
      aiMode: ai === "onDeviceOnly" || ai === "auto" || ai === "useMyClaude" ? ai : "auto",
    };
  } catch {
    return DEFAULT_WEB_PREFS;
  }
}

export function saveWebPref<K extends keyof WebDisplayPrefs>(key: K, value: WebDisplayPrefs[K]): void {
  try {
    localStorage.setItem(KEYS[key], String(value));
  } catch {
    // Ignore storage access errors.
  }
}
