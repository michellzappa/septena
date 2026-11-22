//! Timed reminders (`docs/TIMED_REMINDERS_SPEC.md`). Vectors: `reminders.json`.
//!
//! A reminder is `YYYY-MM-DDTHH:MM` (floating) or a full instant (fixed). The
//! date part moves; the rest of the string stays as written.

use serde::Deserialize;

use crate::date::Day;
use crate::registry::enums::task_status;

/// The reminder of the next occurrence: same time, same day offset from the
/// scheduled date.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn shift_reminder_for_recurrence(
    source_reminder_at: Option<String>,
    source_scheduled: Option<String>,
    next_scheduled: Option<String>,
) -> Option<String> {
    let reminder: Vec<char> = source_reminder_at?.chars().collect();
    let next_date = Day::parse(&next_scheduled?)?;
    if reminder.len() <= 10 || reminder[10] != 'T' {
        return None;
    }
    let reminder_day = Day::parse(&head(&reminder));
    let scheduled_day = source_scheduled.as_deref().and_then(Day::parse);
    let offset = match (reminder_day, scheduled_day) {
        (Some(r), Some(s)) => r.days() - s.days(),
        _ => 0,
    };
    Some(format!("{}{}", next_date.plus_days(offset), tail(&reminder)))
}

/// A reminder on the old scheduled day moves to the new one. Any other
/// reminder stays.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn shift_reminder_on_reschedule(
    reminder_at: Option<String>,
    old_scheduled: Option<String>,
    new_scheduled: Option<String>,
) -> Option<String> {
    let raw = reminder_at?;
    let reminder: Vec<char> = raw.chars().collect();
    let (Some(old), Some(new)) = (old_scheduled.filter(|s| !s.is_empty()), new_scheduled.filter(|s| !s.is_empty()))
    else {
        return Some(raw);
    };
    if reminder.len() <= 10 || reminder[10] != 'T' {
        return Some(raw);
    }
    let old: Vec<char> = old.chars().collect();
    if head(&reminder) != head(&old) {
        return Some(raw);
    }
    let new: Vec<char> = new.chars().collect();
    Some(format!("{}{}", head(&new), tail(&reminder)))
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct ReminderArmInput {
    pub status: String,
    pub is_deleted: bool,
    pub is_heading: bool,
    /// An agent proposal the user has not accepted. It never arms (ADR 0008).
    pub is_unratified_proposal: bool,
    #[serde(default)]
    pub reminder_at: Option<String>,
    #[serde(default)]
    pub reminder_dismissed_at: Option<String>,
}

/// True when the host should schedule an OS notification for the task.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn should_arm_reminder(input: ReminderArmInput) -> bool {
    input.status == task_status::OPEN
        && !input.is_deleted
        && !input.is_heading
        && !input.is_unratified_proposal
        && input.reminder_at.as_deref().is_some_and(|r| !r.is_empty())
        && input.reminder_dismissed_at.is_none()
}

fn head(chars: &[char]) -> String {
    chars.iter().take(10).collect()
}

fn tail(chars: &[char]) -> String {
    chars.iter().skip(10).collect()
}
