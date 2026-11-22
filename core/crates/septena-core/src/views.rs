//! Smart-list membership: Today, its Inbox band, Upcoming, Anytime.
//! Vectors: `task-views.json`.

use serde::{Deserialize, Serialize};

use crate::date::{Day, MS_PER_DAY, parse_instant_ms};
use crate::error::CoreError;
use crate::fade::{day, instant};
use crate::registry::{enums, rules};

/// The task fields that list membership reads.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase", default)]
pub struct TaskSnapshot {
    pub id: String,
    pub title: String,
    pub status: String,
    pub kind: Option<String>,
    pub area: Option<String>,
    pub project: Option<String>,
    pub created: Option<String>,
    pub created_at: Option<String>,
    pub scheduled: Option<String>,
    pub deadline: Option<String>,
    pub today: bool,
    pub today_set_on: Option<String>,
    pub source: Option<String>,
    pub acknowledged_at: Option<String>,
    pub starred: bool,
    pub recurrence_unit: Option<String>,
    pub deleted_at: Option<String>,
    pub faded_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct TaskViewMembership {
    pub is_unfiled: bool,
    pub is_inbox_member: bool,
    pub in_triage_band: bool,
    pub is_on_today: bool,
    /// The Inbox band on Today (the vectors call it `inInbox`).
    pub in_today_inbox: bool,
    pub days_on_today: i64,
    pub matches_today: bool,
    pub matches_inbox: bool,
    pub matches_upcoming: bool,
    pub matches_anytime: bool,
}

/// List membership for one task. `today` is `YYYY-MM-DD` and `now` an
/// ISO-8601 instant, both from the host's day clock.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn task_view_membership(task: TaskSnapshot, today: String, now: String) -> Result<TaskViewMembership, CoreError> {
    let today = day(&today, "today")?;
    let now = instant(&now, "now")?;

    let open = task.status == enums::task_status::OPEN;
    let is_heading = task.kind.as_deref() == Some(enums::task_kind::HEADING);
    let active = open && !is_heading && task.deleted_at.is_none() && task.faded_at.is_none();
    let unfiled = task.area.is_none() && task.project.is_none();
    let scheduled = parse_day(&task.scheduled);
    let deadline = parse_day(&task.deadline);
    let is_on_today =
        active && (task.today || scheduled.is_some_and(|d| d <= today) || deadline.is_some_and(|d| d <= today));
    let is_inbox = active && unfiled;
    let is_mcp = task.source.as_deref() == Some(enums::task_source::MCP);
    let fresh_proposal = is_mcp
        && task
            .created_at
            .as_deref()
            .and_then(parse_instant_ms)
            .is_some_and(|created| now - created < rules::CUE_DECAY_DAYS * MS_PER_DAY);
    let in_triage_band = is_inbox
        && if is_mcp {
            fresh_proposal
                && if task.today || task.scheduled.is_some() || task.deadline.is_some() {
                    task.acknowledged_at.is_none()
                } else {
                    true
                }
        } else {
            task.scheduled.is_none() && task.deadline.is_none() && !task.today
        };
    let in_today_inbox = in_triage_band || (is_inbox && is_on_today);
    let has_agent_cue = is_mcp && task.acknowledged_at.is_none() && fresh_proposal;
    let days_on_today = carried_days(&task, today, open, is_on_today, has_agent_cue);

    Ok(TaskViewMembership {
        is_unfiled: unfiled,
        is_inbox_member: is_inbox,
        in_triage_band,
        is_on_today,
        in_today_inbox,
        days_on_today,
        matches_today: active && (is_on_today || in_triage_band),
        matches_inbox: in_today_inbox,
        matches_upcoming: active
            && !task.today
            && (scheduled.is_some_and(|d| d > today) || deadline.is_some_and(|d| d > today)),
        matches_anytime: active && !task.today && task.scheduled.is_none() && task.deadline.is_none(),
    })
}

fn carried_days(task: &TaskSnapshot, today: Day, open: bool, is_on_today: bool, has_agent_cue: bool) -> i64 {
    if !open || !is_on_today || has_agent_cue {
        return 0;
    }
    let mut landed: Vec<Day> = Vec::new();
    if task.today {
        landed.extend(parse_day(&task.today_set_on));
    }
    landed.extend(parse_day(&task.scheduled).filter(|d| *d <= today));
    landed.extend(parse_day(&task.deadline).filter(|d| *d <= today));
    let Some(landed) = landed.into_iter().min() else {
        return 0;
    };
    let floor = match parse_day(&task.created) {
        Some(created) if created > landed => created,
        _ => landed,
    };
    (today.days() - floor.days()).max(0)
}

fn parse_day(raw: &Option<String>) -> Option<Day> {
    raw.as_deref().and_then(Day::parse)
}
