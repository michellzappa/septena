//! Smart-list membership: Today, its Inbox band, Upcoming, Anytime, and the
//! due state (`docs/TASK_DATES_SPEC.md` §5). Vectors: `task-views.json`.
//!
//! A stored day that is not a valid `YYYY-MM-DD` date reads as no date
//! (invariant I3). Every day comparison uses a parsed `Day`.

use serde::{Deserialize, Serialize};

use crate::date::{Day, MS_PER_DAY, parse_instant_ms};
use crate::error::CoreError;
use crate::fade::{day, instant};
use crate::registry::{enums, rules};

/// The task fields that list membership and the date actions read.
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
    /// The deadline the user planned past (spec §2, I8).
    pub deferred_deadline: Option<String>,
    pub today: bool,
    pub today_set_on: Option<String>,
    pub source: Option<String>,
    pub acknowledged_at: Option<String>,
    pub starred: bool,
    pub recurrence_unit: Option<String>,
    pub deleted_at: Option<String>,
    pub faded_at: Option<String>,
    /// `HH:MM` on the task's day.
    pub start_time: Option<String>,
    pub duration_minutes: Option<i32>,
    pub time_zone: Option<String>,
    pub reminder_at: Option<String>,
    pub reminder_snoozed_until: Option<String>,
    pub reminder_dismissed_at: Option<String>,
    /// False for a fixed repeat. Read only when `recurrence_unit` is set.
    pub recurrence_after_completion: Option<bool>,
    /// The logical slot of a fixed repeat.
    pub recurrence_anchor_date: Option<String>,
    /// Shared projects: true when this task is assigned to another member
    /// (`assignedTo != nil && assignedTo != share.me`). Keeps another member's
    /// task out of personal Anytime, and keeps its shared deadline from pulling
    /// it into personal Today or Upcoming unless the user sets a personal When
    /// or Today pin (`docs/PROJECT_SHARING_SPEC.md` §8).
    pub assigned_to_other: bool,
    /// The conversation's end state. `decomposed` on an open task means the
    /// work goes on elsewhere: the task is tracked (ADR 0065) and leaves the
    /// working lists.
    #[cfg_attr(feature = "ffi", uniffi(default = None))]
    pub end_state: Option<String>,
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
    /// R3: `overdue` (deadline before today) or `dueToday`. None for a task
    /// that is not active or has no arrived deadline.
    pub due_state: Option<String>,
    /// R4: the deadline renders red. A When date never does.
    pub deadline_red: bool,
    /// R5: the Upcoming day, the earlier future date. None outside Upcoming.
    pub upcoming_day: Option<String>,
    /// R8: the task landed on Today this morning by its own date.
    pub arrived_on_own: bool,
    /// An open task whose work goes on elsewhere (`endState = decomposed`,
    /// ADR 0065). It is in Review > Tracked and in no working list: not in
    /// Upcoming, Anytime or an area or project list, and on Today only when
    /// its deadline is due today or past.
    pub is_tracked: bool,
}

/// The values the date actions and the read model share.
pub(crate) struct DateFacts {
    pub active: bool,
    pub scheduled: Option<Day>,
    pub deadline: Option<Day>,
    /// The deadline that can put the task on Today: none when the user
    /// planned past it.
    pub holding_deadline: Option<Day>,
    pub is_on_today: bool,
}

/// I8: the user planned past this deadline. Without a When date to bring the
/// task back, or with another deadline, the deferral does not count.
pub(crate) fn is_deferred(deferred: Option<Day>, scheduled: Option<Day>, deadline: Option<Day>) -> bool {
    scheduled.is_some() && deadline.is_some() && deferred == deadline
}

pub(crate) fn date_facts(task: &TaskSnapshot, today: Day) -> DateFacts {
    let open = task.status == enums::task_status::OPEN;
    let is_heading = task.kind.as_deref() == Some(enums::task_kind::HEADING);
    let active = open && !is_heading && task.deleted_at.is_none() && task.faded_at.is_none();
    let scheduled = parse_day(&task.scheduled);
    let deadline = parse_day(&task.deadline);
    let holding_deadline = deadline
        .filter(|_| !task.assigned_to_other && !is_deferred(parse_day(&task.deferred_deadline), scheduled, deadline));
    let is_on_today =
        active && (task.today || scheduled.is_some_and(|d| d <= today) || holding_deadline.is_some_and(|d| d <= today));
    DateFacts {
        active,
        scheduled,
        deadline,
        holding_deadline,
        is_on_today,
    }
}

/// List membership for one task. `today` is `YYYY-MM-DD` and `now` an
/// ISO-8601 instant, both from the host's day clock.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn task_view_membership(task: TaskSnapshot, today: String, now: String) -> Result<TaskViewMembership, CoreError> {
    let today = day(&today, "today")?;
    let now = instant(&now, "now")?;

    let open = task.status == enums::task_status::OPEN;
    let DateFacts {
        active,
        scheduled,
        deadline,
        holding_deadline,
        is_on_today,
    } = date_facts(&task, today);
    let is_tracked = is_tracked(&task);
    // ADR 0065: a tracked task is on Today only by its own deadline. The
    // user's deadline wins over the work going on elsewhere.
    let deadline_due = holding_deadline.is_some_and(|d| d <= today);
    let is_on_today = if is_tracked {
        active && deadline_due
    } else {
        is_on_today
    };
    let unfiled = task.area.is_none() && task.project.is_none();
    let has_date = scheduled.is_some() || deadline.is_some();
    let is_inbox = active && unfiled;
    let is_mcp = task.source.as_deref() == Some(enums::task_source::MCP);
    let fresh_proposal = is_mcp
        && task
            .created_at
            .as_deref()
            .and_then(parse_instant_ms)
            .is_some_and(|created| now - created < rules::CUE_DECAY_DAYS * MS_PER_DAY);
    let in_triage_band = is_inbox
        && !is_tracked
        && if is_mcp {
            fresh_proposal
                && if task.today || has_date {
                    task.acknowledged_at.is_none()
                } else {
                    true
                }
        } else {
            !has_date && !task.today
        };
    let in_today_inbox = in_triage_band || (is_inbox && is_on_today);
    let has_agent_cue = is_mcp && task.acknowledged_at.is_none() && fresh_proposal;
    let days_on_today = carried_days(&task, holding_deadline, today, open, is_on_today, has_agent_cue);

    let due_state = match deadline {
        Some(d) if active && d < today => Some(DUE_OVERDUE.to_string()),
        Some(d) if active && d == today => Some(DUE_TODAY.to_string()),
        _ => None,
    };
    let upcoming_day = if active && !is_on_today && !is_tracked {
        let personal_deadline = (!task.assigned_to_other).then_some(deadline).flatten();
        [scheduled, personal_deadline]
            .into_iter()
            .flatten()
            .filter(|d| *d > today)
            .min()
    } else {
        None
    };
    let created_before_today = parse_day(&task.created).is_some_and(|c| c < today);
    let arrived_on_own = active
        && !task.today
        && !is_mcp
        && created_before_today
        && ((scheduled == Some(today) && !is_tracked) || holding_deadline == Some(today));

    Ok(TaskViewMembership {
        is_unfiled: unfiled,
        is_inbox_member: is_inbox,
        in_triage_band,
        is_on_today,
        in_today_inbox,
        days_on_today,
        matches_today: active && (is_on_today || in_triage_band),
        matches_inbox: in_today_inbox,
        matches_upcoming: upcoming_day.is_some(),
        matches_anytime: active && !task.today && !has_date && !task.assigned_to_other && !is_tracked,
        deadline_red: due_state.is_some(),
        due_state,
        upcoming_day: upcoming_day.map(|d| d.to_string()),
        arrived_on_own,
        is_tracked,
    })
}

/// ADR 0065: an open task whose conversation ended as `decomposed` (the work
/// goes on as an issue or smaller tasks). Faded or not, it is tracked.
pub(crate) fn is_tracked(task: &TaskSnapshot) -> bool {
    task.status == enums::task_status::OPEN
        && task.kind.as_deref() != Some(enums::task_kind::HEADING)
        && task.deleted_at.is_none()
        && task.end_state.as_deref() == Some(enums::convo_end_state::DECOMPOSED)
}

/// R3 values of `TaskViewMembership::due_state`.
pub const DUE_OVERDUE: &str = "overdue";
pub const DUE_TODAY: &str = "dueToday";

fn carried_days(
    task: &TaskSnapshot,
    holding_deadline: Option<Day>,
    today: Day,
    open: bool,
    is_on_today: bool,
    has_agent_cue: bool,
) -> i64 {
    if !open || !is_on_today || has_agent_cue {
        return 0;
    }
    let mut landed: Vec<Day> = Vec::new();
    if task.today {
        landed.extend(parse_day(&task.today_set_on));
    }
    landed.extend(parse_day(&task.scheduled).filter(|d| *d <= today));
    landed.extend(holding_deadline.filter(|d| *d <= today));
    let Some(landed) = landed.into_iter().min() else {
        return 0;
    };
    let floor = match parse_day(&task.created) {
        Some(created) if created > landed => created,
        _ => landed,
    };
    (today.days() - floor.days()).max(0)
}

pub(crate) fn parse_day(raw: &Option<String>) -> Option<Day> {
    raw.as_deref().and_then(Day::parse)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared_task() -> TaskSnapshot {
        TaskSnapshot {
            id: "s1".into(),
            title: "Call plumber".into(),
            status: "open".into(),
            project: Some("p1".into()),
            source: Some("app".into()),
            created: Some("2026-11-15".into()),
            assigned_to_other: true,
            ..Default::default()
        }
    }

    fn tracked_task() -> TaskSnapshot {
        TaskSnapshot {
            id: "d1".into(),
            title: "Ship the export".into(),
            status: "open".into(),
            area: Some("a1".into()),
            source: Some("app".into()),
            created: Some("2026-11-15".into()),
            end_state: Some("decomposed".into()),
            ..Default::default()
        }
    }

    #[test]
    fn tracked_leaves_the_working_lists() {
        let m = task_view_membership(tracked_task(), "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(m.is_tracked);
        assert!(!m.matches_anytime && !m.matches_today && !m.matches_upcoming && !m.matches_inbox);

        let mut pinned = tracked_task();
        pinned.today = true;
        pinned.scheduled = Some("2026-11-20".into());
        let m = task_view_membership(pinned, "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(!m.matches_today && !m.is_on_today && m.days_on_today == 0);
    }

    #[test]
    fn tracked_with_a_due_deadline_stays_on_today() {
        let mut due = tracked_task();
        due.deadline = Some("2026-11-21".into());
        let m = task_view_membership(due, "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(m.is_tracked && m.matches_today && m.is_on_today);
        assert!(!m.matches_upcoming && !m.matches_anytime);

        let mut later = tracked_task();
        later.deadline = Some("2026-11-25".into());
        let m = task_view_membership(later, "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(!m.matches_today && !m.matches_upcoming && m.upcoming_day.is_none());
    }

    #[test]
    fn assigned_to_other_hides_from_anytime() {
        let m = task_view_membership(shared_task(), "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(!m.matches_anytime);
        assert!(!m.matches_today);
        assert!(!m.matches_upcoming);
    }

    #[test]
    fn assigned_to_other_suppresses_shared_deadline_from_today_and_upcoming() {
        let mut due_today = shared_task();
        due_today.deadline = Some("2026-11-21".into());
        let m = task_view_membership(due_today, "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(!m.matches_today);
        assert!(!m.matches_upcoming);
        assert!(!m.matches_anytime);
        assert!(!m.arrived_on_own);
        assert_eq!(m.due_state.as_deref(), Some(DUE_TODAY));
        assert!(m.deadline_red);

        let mut future_deadline = shared_task();
        future_deadline.deadline = Some("2026-11-28".into());
        let m = task_view_membership(future_deadline, "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(!m.matches_today);
        assert!(!m.matches_upcoming);
        assert_eq!(m.upcoming_day, None);
    }

    #[test]
    fn assigned_to_other_still_honors_personal_when_and_today() {
        let mut scheduled_future = shared_task();
        scheduled_future.scheduled = Some("2026-11-25".into());
        scheduled_future.deadline = Some("2026-11-23".into());
        let m = task_view_membership(scheduled_future, "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(!m.matches_today);
        assert!(m.matches_upcoming);
        assert_eq!(m.upcoming_day.as_deref(), Some("2026-11-25"));

        let mut pinned = shared_task();
        pinned.today = true;
        pinned.today_set_on = Some("2026-11-20".into());
        pinned.deadline = Some("2026-11-18".into());
        let m = task_view_membership(pinned, "2026-11-21".into(), "2026-11-21T12:00:00Z".into()).unwrap();
        assert!(m.matches_today);
        assert!(m.is_on_today);
        assert_eq!(m.days_on_today, 1);
    }
}
