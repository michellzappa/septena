// GENERATED FILE — DO NOT EDIT BY HAND.
// Sources: registry/entities.json, registry/rules.json, registry/destinations.json
// Regenerate: node scripts/gen-registries.mjs
#![allow(dead_code)]

/// Numeric domain constants (`registry/rules.json`).
pub mod rules {
    pub const CUE_DECAY_DAYS: i64 = 7;
    pub const FADE_WINDOW_DAYS: i64 = 14;
    pub const FADE_GRACE_DAYS: i64 = 1;
    pub const FADE_MIN_OPACITY: f64 = 0.55;
    pub const FADE_SWEEP_WEEKDAY: i64 = 1;
    pub const RECENTLY_DELETED_DAYS: i64 = 30;
    pub const UPCOMING_CALENDAR_DAYS: i64 = 30;
    pub const TOAST_DURATION_SECONDS: i64 = 7;
    pub const AGENT_RUN_BUDGET: i64 = 5;
    pub const CLAIM_TTL_DEFAULT_SECONDS: i64 = 1800;
    pub const CLAIM_TTL_MAX_SECONDS: i64 = 14400;
    pub const TOMBSTONE_TTL_DAYS: i64 = 90;
    pub const CLIENT_OP_TTL_DAYS: i64 = 30;
    pub const CHANGE_LOG_TTL_DAYS: i64 = 365;
    pub const DELETE_GRACE_SECONDS: i64 = 120;
}

/// Wire limits (`registry/entities.json` `limits`).
pub mod limits {
    pub const TEXT_MAX: i64 = 2000;
    pub const NOTES_MAX: i64 = 100000;
    pub const ATTACHMENT_POINTER_MAX: i64 = 4000;
    pub const STAMP_MAX: i64 = 40;
    pub const MAX_ATTACHMENT_BYTES: i64 = 26214400;
    pub const MAX_USER_ATTACHMENT_BYTES: i64 = 2147483648;
    pub const MAX_OPS_PER_PUSH: i64 = 500;
    pub const MAX_PULL: i64 = 1000;
    pub const MAX_CHECKLIST_ITEMS_PER_TASK: i64 = 200;
    pub const MAX_TAGS_PER_TASK: i64 = 20;
    pub const TAG_NAME_MAX: i64 = 64;
    pub const MAX_SUBTASKS: i64 = 500;
    pub const MAX_ARTIFACT_REFS: i64 = 100;
    pub const TURN_PROVIDER_MAX: i64 = 32;
    pub const TURN_QUESTION_MAX: i64 = 10000;
    pub const TURN_OPTION_MAX: i64 = 500;
    pub const TURN_MAX_OPTIONS: i64 = 20;
    pub const TURN_CHOSEN_MAX: i64 = 500;
    pub const TURN_OTHER_TEXT_MAX: i64 = 10000;
    pub const TURN_NOTE_MAX: i64 = 100000;
}

/// Canonical enum values (`registry/entities.json` `enums`).
pub mod enums {
    pub mod task_status {
        pub const OPEN: &str = "open";
        pub const DONE: &str = "done";
        pub const CANCELLED: &str = "cancelled";
        pub const ALL: &[&str] = &["open", "done", "cancelled"];
    }
    pub mod task_source {
        pub const APP: &str = "app";
        pub const MCP: &str = "mcp";
        pub const ALL: &[&str] = &["app", "mcp"];
    }
    pub mod project_status {
        pub const ACTIVE: &str = "active";
        pub const DONE: &str = "done";
        pub const CANCELLED: &str = "cancelled";
        pub const ALL: &[&str] = &["active", "done", "cancelled"];
    }
    pub mod task_kind {
        pub const HEADING: &str = "heading";
        pub const ALL: &[&str] = &["heading"];
    }
    pub mod recurrence_unit {
        pub const DAY: &str = "day";
        pub const WEEK: &str = "week";
        pub const MONTH: &str = "month";
        pub const YEAR: &str = "year";
        pub const ALL: &[&str] = &["day", "week", "month", "year"];
    }
    pub mod reminder_mode {
        pub const FLOATING: &str = "floating";
        pub const FIXED: &str = "fixed";
        pub const ALL: &[&str] = &["floating", "fixed"];
    }
    pub mod convo_assignee {
        pub const ME: &str = "me";
        pub const LOCAL: &str = "local";
        pub const CLAUDE: &str = "claude";
        pub const ALL: &[&str] = &["me", "local", "claude"];
    }
    pub mod convo_end_state {
        pub const AGENT_DONE: &str = "agent_done";
        pub const HUMAN_DONE: &str = "human_done";
        pub const AGENT_ASSISTED_DONE: &str = "agent_assisted_done";
        pub const NEEDS_VERIFY: &str = "needs_verify";
        pub const DECOMPOSED: &str = "decomposed";
        pub const REMINDER_SET: &str = "reminder_set";
        pub const PROMOTED_TO_TODAY: &str = "promoted_to_today";
        pub const WONT_DO: &str = "wont_do";
        pub const OPEN: &str = "open";
        pub const ALL: &[&str] = &["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"];
    }
    pub mod convo_handoff_action_type {
        pub const OPEN_URL: &str = "open_url";
        pub const COMPOSE: &str = "compose";
        pub const CALL: &str = "call";
        pub const NONE: &str = "none";
        pub const ALL: &[&str] = &["open_url", "compose", "call", "none"];
    }
    pub mod convo_turn_role {
        pub const USER: &str = "user";
        pub const PROVIDER: &str = "provider";
        pub const ALL: &[&str] = &["user", "provider"];
    }
    pub mod convo_turn_step {
        pub const CONFIRM: &str = "confirm";
        pub const GROUND: &str = "ground";
        pub const SCOPE: &str = "scope";
        pub const DECIDE: &str = "decide";
        pub const WORK: &str = "work";
        pub const ALL: &[&str] = &["confirm", "ground", "scope", "decide", "work"];
    }
    pub mod telemetry_level {
        pub const NONE: &str = "none";
        pub const MINIMAL: &str = "minimal";
        pub const BALANCED: &str = "balanced";
        pub const FULL: &str = "full";
        pub const ALL: &[&str] = &["none", "minimal", "balanced", "full"];
    }
    pub mod appearance_mode {
        pub const SYSTEM: &str = "system";
        pub const LIGHT: &str = "light";
        pub const DARK: &str = "dark";
        pub const ALL: &[&str] = &["system", "light", "dark"];
    }
    pub mod accent_color {
        pub const COLORFUL: &str = "colorful";
        pub const TAMARILLO: &str = "tamarillo";
        pub const PERSIMMON: &str = "persimmon";
        pub const YUZU: &str = "yuzu";
        pub const CARAMBOLA: &str = "carambola";
        pub const ACAI: &str = "acai";
        pub const PITAYA: &str = "pitaya";
        pub const JABUTICABA: &str = "jabuticaba";
        pub const ALL: &[&str] = &["colorful", "tamarillo", "persimmon", "yuzu", "carambola", "acai", "pitaya", "jabuticaba"];
    }
    pub mod app_icon_finish {
        pub const OBSIDIAN: &str = "obsidian";
        pub const CERAMIC: &str = "ceramic";
        pub const FRAMED: &str = "framed";
        pub const ALL: &[&str] = &["obsidian", "ceramic", "framed"];
    }
    pub mod app_icon_color {
        pub const AUTO: &str = "auto";
        pub const PERSIMMON: &str = "persimmon";
        pub const HASKAP: &str = "haskap";
        pub const TAMARILLO: &str = "tamarillo";
        pub const YUZU: &str = "yuzu";
        pub const CARAMBOLA: &str = "carambola";
        pub const ACAI: &str = "acai";
        pub const PITAYA: &str = "pitaya";
        pub const MONO: &str = "mono";
        pub const ALL: &[&str] = &["auto", "persimmon", "haskap", "tamarillo", "yuzu", "carambola", "acai", "pitaya", "mono"];
    }
    pub mod canvas_texture {
        pub const NONE: &str = "none";
        pub const TOPOGRAPHY: &str = "topography";
        pub const FIELD_MATRIX: &str = "fieldMatrix";
        pub const STIPPLE_DRIFT: &str = "stippleDrift";
        pub const CAUSTIC_GLASS: &str = "causticGlass";
        pub const RIDGES: &str = "ridges";
        pub const WASHI_PAPER: &str = "washiPaper";
        pub const ALL: &[&str] = &["none", "topography", "fieldMatrix", "stippleDrift", "causticGlass", "ridges", "washiPaper"];
    }
    pub mod texture_motion {
        pub const STILL: &str = "still";
        pub const SLOW_DRIFT: &str = "slowDrift";
        pub const ALL: &[&str] = &["still", "slowDrift"];
    }
}

/// Synced entity names (`registry/entities.json` `entities`).
pub mod entity_names {
    pub const TASK: &str = "task";
    pub const AREA: &str = "area";
    pub const PROJECT: &str = "project";
    pub const ATTACHMENT: &str = "attachment";
    pub const CHECKLIST_ITEM: &str = "checklistItem";
    pub const TAG: &str = "tag";
    pub const CONVO: &str = "convo";
    pub const SETTING: &str = "setting";
}

/// Destination IDs (`registry/destinations.json`).
pub mod destination_ids {
    pub const INBOX: &str = "inbox";
    pub const TODAY: &str = "today";
    pub const REVIEW: &str = "review";
    pub const AGENT: &str = "agent";
    pub const UPCOMING: &str = "upcoming";
    pub const REPEATING: &str = "repeating";
    pub const ANYTIME: &str = "anytime";
    pub const LOGBOOK: &str = "logbook";
    pub const STARRED: &str = "starred";
    pub const FADED: &str = "faded";
    pub const RECENTLY_DELETED: &str = "recentlyDeleted";
}
