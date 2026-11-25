//! Do: one task now (ADR 0041, `docs/DO_SPEC.md` §2). Vectors: `do-session.json`.

use serde::{Deserialize, Serialize};

use crate::date::{Day, MS_PER_DAY, parse_instant_ms};
use crate::error::CoreError;
use crate::fade::instant;
use crate::registry::enums::{do_exit, task_status};
use crate::registry::rules;

const MS_PER_MINUTE: i64 = 60_000;
const MS_PER_HOUR: i64 = 60 * MS_PER_MINUTE;

/// One Do. `task_status` is the status of its task now; none means the task
/// is gone (deleted or faded).
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct DoSession {
    pub id: String,
    pub started_at: String,
    #[serde(default)]
    pub planned_minutes: Option<i64>,
    #[serde(default)]
    pub confirmed_at: Option<String>,
    #[serde(default)]
    pub ended_at: Option<String>,
    #[serde(default)]
    pub task_status: Option<String>,
}

/// How one open Do ends.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct DoEnd {
    pub id: String,
    pub ended_at: String,
    pub exit: String,
    /// The length is unknown.
    pub lapsed: bool,
}

/// The Do that stays open. Times are milliseconds since 1970.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct CurrentDo {
    pub id: String,
    pub started_ms: i64,
    pub planned_end_ms: Option<i64>,
    pub stale_at_ms: i64,
    pub is_stale: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct DoResolution {
    /// The open rows that end now, oldest first.
    pub ends: Vec<DoEnd>,
    pub current: Option<CurrentDo>,
}

/// Which open Do stays open, and how each other one ends (§2.1, §2.2). The
/// host passes every open row and every row that started after the oldest
/// open one, so the result does not depend on the order of sync.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn resolve_do_sessions(sessions: Vec<DoSession>, now: String) -> Result<DoResolution, CoreError> {
    let now_ms = instant(&now, "now")?;
    let mut rows = sessions.into_iter().map(Row::of).collect::<Result<Vec<_>, _>>()?;
    rows.sort_by(|a, b| (a.started, &a.session.id).cmp(&(b.started, &b.session.id)));

    let mut ends = Vec::new();
    let mut current = None;
    for (index, row) in rows.iter().enumerate() {
        if row.session.ended_at.is_some() {
            continue;
        }
        let stale_at = row.stale_at();
        let end = |ended_at: String, exit: &str, lapsed: bool| DoEnd {
            id: row.session.id.clone(),
            ended_at,
            exit: exit.to_string(),
            lapsed,
        };
        if let Some(next) = rows.get(index + 1) {
            ends.push(end(
                next.session.started_at.clone(),
                do_exit::REPLACED,
                next.started >= stale_at,
            ));
        } else if row.session.task_status.as_deref() != Some(task_status::OPEN) {
            let done = row.session.task_status.as_deref() == Some(task_status::DONE);
            let exit = if done { do_exit::DONE } else { do_exit::CLOSED };
            // A device clock that runs ahead must not end a Do before it starts.
            let at = if now_ms < row.started {
                row.session.started_at.clone()
            } else {
                now.clone()
            };
            ends.push(end(at, exit, now_ms >= stale_at));
        } else if now_ms - stale_at >= rules::DO_LAPSE_HOURS * MS_PER_HOUR {
            ends.push(end(format_instant(stale_at), do_exit::STOPPED, true));
        } else {
            current = Some(CurrentDo {
                id: row.session.id.clone(),
                started_ms: row.started,
                planned_end_ms: row.planned_end(),
                stale_at_ms: stale_at,
                is_stale: now_ms >= stale_at,
            });
        }
    }
    Ok(DoResolution { ends, current })
}

/// True when an end at `incoming` wins over the stored end at `current`: the
/// earliest end stays (§2.1 rule 2).
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn do_end_wins(current: Option<String>, incoming: String) -> Result<bool, CoreError> {
    let incoming = instant(&incoming, "incoming")?;
    match current {
        None => Ok(true),
        Some(current) => Ok(incoming < instant(&current, "current")?),
    }
}

struct Row {
    session: DoSession,
    started: i64,
    confirmed: Option<i64>,
}

impl Row {
    fn of(session: DoSession) -> Result<Row, CoreError> {
        let started = instant(&session.started_at, "startedAt")?;
        let confirmed = session.confirmed_at.as_deref().and_then(parse_instant_ms);
        Ok(Row {
            session,
            started,
            confirmed,
        })
    }

    fn planned_end(&self) -> Option<i64> {
        self.session
            .planned_minutes
            .filter(|minutes| *minutes > 0)
            .map(|minutes| self.started + minutes * MS_PER_MINUTE)
    }

    fn stale_at(&self) -> i64 {
        let base = self.confirmed.map_or(self.started, |c| c.max(self.started));
        let limit = base + rules::DO_STALE_HOURS * MS_PER_HOUR;
        self.planned_end().map_or(limit, |end| end.max(limit))
    }
}

/// `YYYY-MM-DDTHH:MM:SS.mmmZ`.
fn format_instant(ms: i64) -> String {
    let day = Day::EPOCH.plus_days(ms.div_euclid(MS_PER_DAY));
    let rest = ms.rem_euclid(MS_PER_DAY);
    format!(
        "{day}T{:02}:{:02}:{:02}.{:03}Z",
        rest / MS_PER_HOUR,
        rest / MS_PER_MINUTE % 60,
        rest / 1000 % 60,
        rest % 1000
    )
}
