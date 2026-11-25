//! Do: one task now (ADR 0041, `docs/DO_SPEC.md` §2). Vectors: `do-session.json`.
//!
//! JSON in, JSON out: hosts call these through `invoke_json`. Typed bindings
//! for rows and results do not fit the native size budget (spec §6).

use serde_json::{Value, json};

use crate::date::{Day, MS_PER_DAY, parse_instant_ms};
use crate::error::CoreError;
use crate::fade::instant;
use crate::registry::enums::{do_exit, task_status};
use crate::registry::rules;

const MS_PER_MINUTE: i64 = 60_000;
const MS_PER_HOUR: i64 = 60 * MS_PER_MINUTE;

struct Row<'a> {
    id: &'a str,
    started_at: &'a str,
    started: i64,
    planned_end: Option<i64>,
    stale_at: i64,
    is_open: bool,
    task_status: Option<&'a str>,
}

/// Which open Do stays open, and how each other one ends (§2.1, §2.2).
///
/// `sessions`: every open row and every row that started after the oldest
/// open one, in any order, each with `id`, `startedAt`, `plannedMinutes`,
/// `confirmedAt`, `endedAt` and `taskStatus` (the status of its task now; none
/// means the task is deleted or faded). Returns `ends` (oldest first) and
/// `current`, whose times are milliseconds since 1970.
pub(crate) fn resolve_do_sessions(sessions: &Value, now: &str) -> Result<Value, CoreError> {
    let now_ms = instant(now, "now")?;
    let mut rows: Vec<Row> = Vec::new();
    for session in sessions.as_array().into_iter().flatten() {
        let row = Row::of(session)?;
        let at = rows
            .iter()
            .position(|other| (other.started, other.id) > (row.started, row.id))
            .unwrap_or(rows.len());
        rows.insert(at, row);
    }

    let mut ends = Vec::new();
    let mut current = Value::Null;
    for (index, row) in rows.iter().enumerate() {
        if !row.is_open {
            continue;
        }
        let stale = now_ms >= row.stale_at;
        let (ended_at, exit, lapsed) = if let Some(next) = rows.get(index + 1) {
            let lapsed = next.started >= row.stale_at;
            (next.started_at.to_string(), do_exit::REPLACED, lapsed)
        } else if row.task_status != Some(task_status::OPEN) {
            let done = row.task_status == Some(task_status::DONE);
            // A device clock that runs ahead must not end a Do before it starts.
            let at = if now_ms < row.started { row.started_at } else { now };
            let exit = if done { do_exit::DONE } else { do_exit::CLOSED };
            (at.to_string(), exit, stale)
        } else if now_ms - row.stale_at >= rules::DO_LAPSE_HOURS * MS_PER_HOUR {
            (format_instant(row.stale_at), do_exit::STOPPED, true)
        } else {
            current = json!({
                "id": row.id,
                "startedMs": row.started,
                "plannedEndMs": row.planned_end,
                "staleAtMs": row.stale_at,
                "isStale": stale,
            });
            continue;
        };
        ends.push(json!({ "id": row.id, "endedAt": ended_at, "exit": exit, "lapsed": lapsed }));
    }
    Ok(json!({ "ends": ends, "current": current }))
}

/// True when an end at `incoming` wins over the stored end at `current`: the
/// earliest end stays (§2.1 rule 2).
pub(crate) fn do_end_wins(current: Option<&str>, incoming: &str) -> Result<bool, CoreError> {
    let incoming = instant(incoming, "incoming")?;
    match current {
        None => Ok(true),
        Some(current) => Ok(incoming < instant(current, "current")?),
    }
}

impl Row<'_> {
    fn of(session: &Value) -> Result<Row<'_>, CoreError> {
        let text = |name: &str| session[name].as_str();
        let started_at = text("startedAt").unwrap_or_default();
        let started = instant(started_at, "startedAt")?;
        let planned_end = match session["plannedMinutes"].as_i64() {
            Some(minutes) if minutes > 0 => Some(started + minutes * MS_PER_MINUTE),
            _ => None,
        };
        let confirmed = text("confirmedAt").and_then(parse_instant_ms).unwrap_or(started);
        let limit = confirmed.max(started) + rules::DO_STALE_HOURS * MS_PER_HOUR;
        Ok(Row {
            id: text("id").unwrap_or_default(),
            started_at,
            started,
            planned_end,
            stale_at: planned_end.unwrap_or(limit).max(limit),
            is_open: text("endedAt").is_none(),
            task_status: text("taskStatus"),
        })
    }
}

/// `YYYY-MM-DDTHH:MM:SS.mmmZ`.
fn format_instant(ms: i64) -> String {
    let day = Day::EPOCH.plus_days(ms.div_euclid(MS_PER_DAY));
    let rest = ms.rem_euclid(MS_PER_DAY);
    let (hours, minutes) = (rest / MS_PER_HOUR, rest / MS_PER_MINUTE % 60);
    let (seconds, millis) = (rest / 1000 % 60, rest % 1000);
    format!("{day}T{hours:02}:{minutes:02}:{seconds:02}.{millis:03}Z")
}
