//! Task date actions (`docs/TASK_DATES_SPEC.md` §3–§4, ADR 0027). Vectors:
//! `task-dates.json`.
//!
//! A shell names an action; the core returns the date fields after it. The
//! host writes the changed fields in one save. Every result meets invariants
//! I1–I8. The core never reads a clock: the host passes `today` and `now`.

use serde::{Deserialize, Serialize};

use crate::date::Day;
use crate::error::CoreError;
use crate::fade::{day, instant};
use crate::registry::enums;
use crate::reminders::{shift_reminder_for_recurrence, shift_reminder_on_reschedule};
use crate::views::{TaskSnapshot, date_facts, is_deferred, parse_day};

/// The answer to "this occurrence or the whole series" for a fixed repeat.
/// Other tasks ignore it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[serde(rename_all = "camelCase")]
pub enum RescheduleMode {
    /// Move this occurrence only. The series keeps its slot.
    #[default]
    MakeException,
    /// Move the series. The host rebases the other open copies.
    UpdateRule,
}

/// A date action of spec §4. The comment on each variant names its spec ID.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum DateAction {
    /// A1. Put the task on Today. Replaces its When date (I1).
    PutOnToday {
        #[serde(default)]
        mode: RescheduleMode,
    },
    /// A2. Plan the task for `day`. A day on or before today is A1.
    ScheduleFor {
        day: String,
        #[serde(default)]
        mode: RescheduleMode,
    },
    /// A3. Take the task off Today. An arrived When date or deadline goes too
    /// (decision Q2).
    RemoveFromToday,
    /// A4. A3 when the task is on Today (R2), else A1.
    ToggleToday {
        #[serde(default)]
        mode: RescheduleMode,
    },
    /// A5. Clear the When date. The deadline stays (I5).
    ClearWhenDate,
    /// A6. Clear When: When date, deadline, pin and time slot all go.
    ClearWhen,
    /// A7 (a day) and A8 (none). Set or clear the deadline.
    SetDeadline {
        #[serde(default)]
        day: Option<String>,
    },
    /// A9. Set or clear the time slot. A time with no day pins the task.
    SetTimeSlot {
        #[serde(default)]
        start_time: Option<String>,
        #[serde(default)]
        duration_minutes: Option<i32>,
        #[serde(default)]
        time_zone: Option<String>,
    },
    /// A11. File the task from the triage band: A1, unless the task has a
    /// future When date, which it keeps.
    FileFromTriage,
}

/// Every task field a date action can write.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct TaskDateFields {
    pub scheduled: Option<String>,
    pub deadline: Option<String>,
    pub deferred_deadline: Option<String>,
    pub today: bool,
    pub today_set_on: Option<String>,
    pub start_time: Option<String>,
    pub duration_minutes: Option<i32>,
    pub time_zone: Option<String>,
    pub reminder_at: Option<String>,
    pub reminder_snoozed_until: Option<String>,
    pub reminder_dismissed_at: Option<String>,
    pub recurrence_anchor_date: Option<String>,
    pub acknowledged_at: Option<String>,
}

/// The fields after an action, and the camelCase names of the ones that
/// changed. The host writes only the changed fields.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct TaskDatePatch {
    pub fields: TaskDateFields,
    pub changed: Vec<String>,
}

/// The shortest and longest time slot, in minutes.
const SLOT_MINUTES: (i32, i32) = (5, 1440);

/// Applies one date action to one task. A heading or a deleted task has no
/// dates to change: the patch is empty. Every action also clears the agent
/// cue of an agent row. `today` is `YYYY-MM-DD` and `now` an ISO-8601
/// instant, both from the host's day clock.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn apply_date_action(
    task: TaskSnapshot,
    action: DateAction,
    today: String,
    now: String,
) -> Result<TaskDatePatch, CoreError> {
    let today = day(&today, "today")?;
    instant(&now, "now")?;
    let before = fields_of(&task);
    if task.deleted_at.is_some() || task.kind.as_deref() == Some(enums::task_kind::HEADING) {
        return Ok(patch(&before, before.clone()));
    }
    let mut ctx = Ctx {
        task: &task,
        today,
        f: before.clone(),
    };
    ctx.run(action)?;
    if task.source.as_deref() == Some(enums::task_source::MCP) && ctx.f.acknowledged_at.is_none() {
        ctx.f.acknowledged_at = Some(now);
    }
    let mut after = ctx.f;
    normalize(&mut after, today);
    Ok(patch(&before, after))
}

/// A12 and restore: the task's fields brought to invariants I1–I8. A pin
/// with a future When date loses the pin; a pin with an arrived When date
/// loses the date. An empty or invalid day becomes none.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn normalize_task_dates(task: TaskSnapshot, today: String) -> Result<TaskDatePatch, CoreError> {
    let today = day(&today, "today")?;
    let before = fields_of(&task);
    let mut after = before.clone();
    normalize(&mut after, today);
    Ok(patch(&before, after))
}

/// A10: the date fields of the next occurrence of a repeating task, due on
/// `next_scheduled`. No deadline, no pin, the same time slot, the reminder
/// shifted to the new day. An agent row arrives acknowledged.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn next_occurrence_dates(
    task: TaskSnapshot,
    next_scheduled: String,
    now: String,
) -> Result<TaskDateFields, CoreError> {
    let next = day(&next_scheduled, "nextScheduled")?.to_string();
    instant(&now, "now")?;
    let fixed = is_fixed_repeat(&task);
    let reminder_at = shift_reminder_for_recurrence(
        task.reminder_at.clone(),
        task.recurrence_anchor_date.clone().or_else(|| task.scheduled.clone()),
        Some(next.clone()),
    );
    let acknowledged_at = if task.source.as_deref() == Some(enums::task_source::MCP) {
        Some(now)
    } else {
        task.acknowledged_at.clone()
    };
    Ok(TaskDateFields {
        scheduled: Some(next.clone()),
        deadline: None,
        deferred_deadline: None,
        today: false,
        today_set_on: None,
        start_time: task.start_time.clone(),
        duration_minutes: task.duration_minutes,
        time_zone: task.time_zone.clone(),
        reminder_at,
        reminder_snoozed_until: None,
        reminder_dismissed_at: None,
        recurrence_anchor_date: fixed.then_some(next),
        acknowledged_at,
    })
}

struct Ctx<'a> {
    task: &'a TaskSnapshot,
    today: Day,
    f: TaskDateFields,
}

impl Ctx<'_> {
    fn run(&mut self, action: DateAction) -> Result<(), CoreError> {
        match action {
            DateAction::PutOnToday { mode } => self.put_on_today(mode),
            DateAction::ScheduleFor { day: raw, mode } => {
                let target = day(&raw, "day")?;
                if target <= self.today {
                    self.put_on_today(mode);
                } else {
                    self.schedule_for(target, mode);
                }
            }
            DateAction::RemoveFromToday => self.remove_from_today(),
            DateAction::ToggleToday { mode } => {
                if date_facts(self.task, self.today).is_on_today {
                    self.remove_from_today();
                } else {
                    self.put_on_today(mode);
                }
            }
            DateAction::ClearWhenDate => {
                self.f.scheduled = None;
                self.unpin();
                self.clear_slot();
            }
            DateAction::ClearWhen => {
                self.f.scheduled = None;
                self.f.deadline = None;
                self.unpin();
                self.clear_slot();
            }
            DateAction::SetDeadline { day: raw } => {
                let target = match raw.filter(|s| !s.is_empty()) {
                    Some(raw) => Some(day(&raw, "day")?),
                    None => None,
                };
                self.set_deadline(target);
            }
            DateAction::SetTimeSlot {
                start_time,
                duration_minutes,
                time_zone,
            } => self.set_time_slot(start_time, duration_minutes, time_zone)?,
            DateAction::FileFromTriage => {
                let future_when = parse_day(&self.f.scheduled).is_some_and(|d| d > self.today);
                if !future_when {
                    self.put_on_today(RescheduleMode::MakeException);
                }
            }
        }
        Ok(())
    }

    /// A1. A dated row first moves its occurrence to today, so a fixed repeat
    /// keeps its slot and a reminder on the old When day follows. Then the
    /// date goes: a pinned row has no When date (I1).
    fn put_on_today(&mut self, mode: RescheduleMode) {
        if let Some(old) = parse_day(&self.f.scheduled) {
            self.record_slot(old, self.today, mode);
            self.shift_reminder(old, self.today);
        }
        self.f.scheduled = None;
        self.pin();
    }

    /// A2 for a day after today. The deadline stays (decision Q1). An arrived
    /// one no longer holds the task on Today: the user planned past it
    /// (decision Q8).
    fn schedule_for(&mut self, target: Day, mode: RescheduleMode) {
        if let Some(old) = parse_day(&self.f.scheduled) {
            self.record_slot(old, target, mode);
            self.shift_reminder(old, target);
        } else if is_fixed_repeat(self.task) && mode == RescheduleMode::UpdateRule {
            self.f.recurrence_anchor_date = Some(target.to_string());
        }
        self.f.scheduled = Some(target.to_string());
        if parse_day(&self.f.deadline).is_some_and(|d| d <= self.today) {
            self.f.deferred_deadline = self.f.deadline.clone();
        }
        self.unpin();
    }

    /// A3. Membership is a union (pin, arrived When, arrived deadline), so
    /// the arrived dates go too, or the row would bounce straight back. A
    /// deadline the user planned past does not hold the row, so it stays.
    fn remove_from_today(&mut self) {
        self.unpin();
        let facts = date_facts(self.task, self.today);
        let when_arrived = facts.scheduled.is_some_and(|d| d <= self.today);
        let deadline_arrived = facts.deadline.is_some_and(|d| d <= self.today);
        if when_arrived {
            self.f.scheduled = None;
        }
        if !self.task.assigned_to_other && deadline_arrived && (when_arrived || facts.holding_deadline.is_some()) {
            self.f.deadline = None;
        }
        if self.f.scheduled.is_none() && !self.f.today {
            self.clear_slot();
        }
    }

    /// A7 and A8, with the keep-on-Today rule: a row that only its old
    /// deadline held on Today is pinned when the new deadline does not hold
    /// it there.
    fn set_deadline(&mut self, target: Option<Day>) {
        let held_by_when = parse_day(&self.f.scheduled).is_some_and(|d| d <= self.today);
        let new_holds = target.is_some_and(|d| d <= self.today);
        let on_today = date_facts(self.task, self.today).is_on_today;
        if !self.f.today && on_today && !held_by_when && !new_holds {
            self.pin();
        }
        self.f.deadline = target.map(|d| d.to_string());
    }

    fn set_time_slot(
        &mut self,
        start_time: Option<String>,
        duration_minutes: Option<i32>,
        time_zone: Option<String>,
    ) -> Result<(), CoreError> {
        let Some(start) = start_time.filter(|s| !s.is_empty()) else {
            self.clear_slot();
            return Ok(());
        };
        if !is_clock_time(&start) {
            return Err(CoreError::invalid(format!("`startTime` is not HH:MM: {start}")));
        }
        self.f.start_time = Some(start);
        self.f.duration_minutes = duration_minutes.map(|m| m.clamp(SLOT_MINUTES.0, SLOT_MINUTES.1));
        self.f.time_zone = time_zone.filter(|z| !z.is_empty());
        if self.f.scheduled.is_none() && !self.f.today {
            self.pin();
        }
        Ok(())
    }

    /// The slot of a fixed repeat before its occurrence moves from `old` to
    /// `new`. An exception records the old slot once; a series move takes
    /// the new day as its slot.
    fn record_slot(&mut self, old: Day, new: Day, mode: RescheduleMode) {
        if !is_fixed_repeat(self.task) {
            return;
        }
        match mode {
            RescheduleMode::MakeException => {
                if parse_day(&self.f.recurrence_anchor_date).is_none() {
                    self.f.recurrence_anchor_date = Some(old.to_string());
                }
            }
            RescheduleMode::UpdateRule => self.f.recurrence_anchor_date = Some(new.to_string()),
        }
    }

    /// A reminder on the old When day moves to the new one. A moved reminder
    /// is armed again: its snooze and dismissal go.
    fn shift_reminder(&mut self, old: Day, new: Day) {
        let shifted =
            shift_reminder_on_reschedule(self.f.reminder_at.clone(), Some(old.to_string()), Some(new.to_string()));
        if shifted != self.f.reminder_at {
            self.f.reminder_at = shifted;
            self.f.reminder_snoozed_until = None;
            self.f.reminder_dismissed_at = None;
        }
    }

    /// I2: the stamp is set only on the change false → true.
    fn pin(&mut self) {
        if !self.f.today {
            self.f.today = true;
            self.f.today_set_on = Some(self.today.to_string());
        }
    }

    fn unpin(&mut self) {
        self.f.today = false;
        self.f.today_set_on = None;
    }

    fn clear_slot(&mut self) {
        self.f.start_time = None;
        self.f.duration_minutes = None;
        self.f.time_zone = None;
    }
}

/// Brings fields to invariants I1–I8.
fn normalize(f: &mut TaskDateFields, today: Day) {
    // I3, I4: a day is a valid date or none.
    for value in [
        &mut f.scheduled,
        &mut f.deadline,
        &mut f.deferred_deadline,
        &mut f.today_set_on,
        &mut f.recurrence_anchor_date,
    ] {
        if value.as_deref().and_then(Day::parse).is_none() {
            *value = None;
        }
    }
    for value in [
        &mut f.start_time,
        &mut f.time_zone,
        &mut f.reminder_at,
        &mut f.reminder_snoozed_until,
        &mut f.reminder_dismissed_at,
    ] {
        if value.as_deref().is_some_and(str::is_empty) {
            *value = None;
        }
    }
    // I1: a future When date wins over a pin; an arrived one gives way to it.
    if f.today
        && let Some(scheduled) = parse_day(&f.scheduled)
    {
        if scheduled > today {
            f.today = false;
        } else {
            f.scheduled = None;
        }
    }
    // I2.
    if !f.today {
        f.today_set_on = None;
    } else if f.today_set_on.is_none() {
        f.today_set_on = Some(today.to_string());
    }
    // I8: a deferral lasts as long as the deadline it names and the When date
    // that brings the task back.
    if !is_deferred(
        parse_day(&f.deferred_deadline),
        parse_day(&f.scheduled),
        parse_day(&f.deadline),
    ) {
        f.deferred_deadline = None;
    }
    // I6: a time slot needs a day (a When date, a pin or an arrived deadline).
    let held = f.scheduled.is_some() || f.today || parse_day(&f.deadline).is_some_and(|d| d <= today);
    if !held {
        f.start_time = None;
    }
    // I7.
    if f.start_time.is_none() {
        f.duration_minutes = None;
        f.time_zone = None;
    }
}

fn fields_of(task: &TaskSnapshot) -> TaskDateFields {
    TaskDateFields {
        scheduled: task.scheduled.clone(),
        deadline: task.deadline.clone(),
        deferred_deadline: task.deferred_deadline.clone(),
        today: task.today,
        today_set_on: task.today_set_on.clone(),
        start_time: task.start_time.clone(),
        duration_minutes: task.duration_minutes,
        time_zone: task.time_zone.clone(),
        reminder_at: task.reminder_at.clone(),
        reminder_snoozed_until: task.reminder_snoozed_until.clone(),
        reminder_dismissed_at: task.reminder_dismissed_at.clone(),
        recurrence_anchor_date: task.recurrence_anchor_date.clone(),
        acknowledged_at: task.acknowledged_at.clone(),
    }
}

/// One loop, not one comparison per field: the native slices are close to
/// their size budget.
fn patch(before: &TaskDateFields, after: TaskDateFields) -> TaskDatePatch {
    let texts = [
        ("scheduled", &before.scheduled, &after.scheduled),
        ("deadline", &before.deadline, &after.deadline),
        ("deferredDeadline", &before.deferred_deadline, &after.deferred_deadline),
        ("todaySetOn", &before.today_set_on, &after.today_set_on),
        ("startTime", &before.start_time, &after.start_time),
        ("timeZone", &before.time_zone, &after.time_zone),
        ("reminderAt", &before.reminder_at, &after.reminder_at),
        (
            "reminderSnoozedUntil",
            &before.reminder_snoozed_until,
            &after.reminder_snoozed_until,
        ),
        (
            "reminderDismissedAt",
            &before.reminder_dismissed_at,
            &after.reminder_dismissed_at,
        ),
        (
            "recurrenceAnchorDate",
            &before.recurrence_anchor_date,
            &after.recurrence_anchor_date,
        ),
        ("acknowledgedAt", &before.acknowledged_at, &after.acknowledged_at),
    ];
    let mut changed: Vec<String> = texts
        .iter()
        .filter(|(_, old, new)| old != new)
        .map(|(name, _, _)| name.to_string())
        .collect();
    if before.today != after.today {
        changed.push("today".to_string());
    }
    if before.duration_minutes != after.duration_minutes {
        changed.push("durationMinutes".to_string());
    }
    TaskDatePatch { fields: after, changed }
}

/// The changed fields as one JSON object, the shape of the vectors.
pub(crate) fn patch_json(p: &TaskDatePatch) -> serde_json::Value {
    let all = serde_json::to_value(&p.fields).unwrap_or_default();
    let mut out = serde_json::Map::new();
    for name in &p.changed {
        out.insert(name.clone(), all.get(name).cloned().unwrap_or_default());
    }
    serde_json::Value::Object(out)
}

fn is_fixed_repeat(task: &TaskSnapshot) -> bool {
    task.recurrence_unit.is_some() && task.recurrence_after_completion == Some(false)
}

fn is_clock_time(raw: &str) -> bool {
    let b = raw.as_bytes();
    b.len() == 5
        && b[2] == b':'
        && b[..2].iter().chain(&b[3..]).all(u8::is_ascii_digit)
        && (b[0] - b'0') * 10 + (b[1] - b'0') < 24
        && (b[3] - b'0') * 10 + (b[4] - b'0') < 60
}
