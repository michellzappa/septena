//! Recurrence arithmetic (`docs/RECURRENCE_V2_SPEC.md`). Vectors: `recurrence.json`.
//!
//! Weekdays use the Apple convention: 1 = Sunday … 7 = Saturday.

use serde::Deserialize;

use crate::date::{Day, YearMonth};
use crate::registry::enums::recurrence_unit;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct OrdinalWeekday {
    /// 1…4, or -1 for the last one in the month.
    pub ordinal: i32,
    /// 1 = Sunday … 7 = Saturday.
    pub weekday: i32,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct RecurrenceRule {
    pub unit: String,
    #[serde(default = "one")]
    pub interval: i32,
    #[serde(default = "yes")]
    pub after_completion: bool,
    #[serde(default)]
    pub weekdays: Option<Vec<i32>>,
    #[serde(default)]
    pub month_day: Option<i32>,
    #[serde(default)]
    pub ordinal_weekday: Option<OrdinalWeekday>,
}

fn one() -> i32 {
    1
}

fn yes() -> bool {
    true
}

/// The next scheduled date (`YYYY-MM-DD`) after a completion, or none when the
/// rule cannot produce one. A fixed schedule catches up strictly past
/// `completed_on`; `logical_scheduled` is the occurrence's date before an
/// exception moved it.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn next_scheduled_date(
    completed_on: String,
    scheduled: Option<String>,
    logical_scheduled: Option<String>,
    rule: RecurrenceRule,
) -> Option<String> {
    let completed = Day::parse(&completed_on)?;
    let anchor = if rule.after_completion {
        completed
    } else {
        logical_scheduled
            .or(scheduled)
            .as_deref()
            .and_then(Day::parse)
            .unwrap_or(completed)
    };
    let step = i64::from(rule.interval.max(1));
    let fixed = !rule.after_completion;
    let weekdays = if fixed {
        normalize_weekdays(rule.weekdays.as_deref())
    } else {
        Vec::new()
    };
    let month_day = if fixed { rule.month_day } else { None };
    let ordinal = if fixed { rule.ordinal_weekday } else { None };
    let keep_month_end = fixed && month_day.is_none() && ordinal.is_none();

    let advance = |date: Day| -> Option<Day> {
        match rule.unit.as_str() {
            recurrence_unit::DAY => Some(date.plus_days(step)),
            recurrence_unit::WEEK => {
                if weekdays.is_empty() {
                    Some(date.plus_days(step * 7))
                } else {
                    advance_weekly_by_weekdays(date, step, &weekdays)
                }
            }
            recurrence_unit::MONTH => {
                let target = YearMonth::of(date).plus_months(step);
                if let Some(ordinal) = ordinal {
                    resolve_ordinal_weekday(target, ordinal)
                } else if let Some(month_day) = month_day {
                    resolve_month_day(target, month_day)
                } else {
                    let keep_end = keep_month_end && date.day_of_month() == YearMonth::of(date).length();
                    let target_day = if keep_end {
                        target.length()
                    } else {
                        date.day_of_month().min(target.length())
                    };
                    target.at_day(target_day)
                }
            }
            recurrence_unit::YEAR => {
                let target = YearMonth {
                    year: date.year() + step,
                    month: date.month(),
                };
                if let Some(ordinal) = ordinal {
                    resolve_ordinal_weekday(target, ordinal)
                } else if let Some(month_day) = month_day {
                    resolve_month_day(target, month_day)
                } else {
                    target.at_day(date.day_of_month().min(target.length()))
                }
            }
            _ => None,
        }
    };

    let mut next = advance(anchor)?;
    if fixed {
        let mut guard = 0;
        while next <= completed {
            guard += 1;
            if guard > 10_000 {
                return None;
            }
            next = advance(next)?;
        }
    }
    Some(next.to_string())
}

/// The stable record id of one occurrence: FNV-1a 64 over `"<id>|<date>"`.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn occurrence_id(source_task_id: String, scheduled: String) -> String {
    format!("recur-{}", fnv1a64(&format!("{source_task_id}|{scheduled}")))
}

/// The stable id of a checklist item copied onto a new occurrence: FNV-1a 64
/// over `"<new task id>|chk|<index>|<source item id>"`. A phone and an agent
/// completing the same task copy the same items to the same ids.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn checklist_occurrence_id(new_task_id: String, index: u32, source_item_id: String) -> String {
    format!("chk-{}", fnv1a64(&format!("{new_task_id}|chk|{index}|{source_item_id}")))
}

fn fnv1a64(input: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in input.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// Days after Monday for an Apple weekday (1 = Sunday).
fn iso_offset(sunday_first_weekday: i32) -> i64 {
    i64::from((sunday_first_weekday + 5) % 7)
}

fn normalize_weekdays(values: Option<&[i32]>) -> Vec<i32> {
    let mut out: Vec<i32> = Vec::new();
    for &value in values.unwrap_or(&[]) {
        if (1..=7).contains(&value) && !out.contains(&value) {
            out.push(value);
        }
    }
    out.sort_by_key(|w| iso_offset(*w));
    out
}

fn advance_weekly_by_weekdays(date: Day, step: i64, weekdays: &[i32]) -> Option<Day> {
    let sunday_first = (date.iso_weekday() % 7 + 1) as i32;
    let current = iso_offset(sunday_first);
    for &weekday in weekdays {
        let offset = iso_offset(weekday);
        if offset > current {
            return Some(date.plus_days(offset - current));
        }
    }
    let first = *weekdays.first()?;
    let monday = date.plus_days(-current);
    Some(monday.plus_days(step * 7 + iso_offset(first)))
}

fn resolve_month_day(month: YearMonth, month_day: i32) -> Option<Day> {
    match month_day {
        -1 => Some(month.at_end()),
        1..=31 => month.at_day((month_day as u32).min(month.length())),
        _ => None,
    }
}

fn resolve_ordinal_weekday(month: YearMonth, value: OrdinalWeekday) -> Option<Day> {
    if !(1..=7).contains(&value.weekday) || (value.ordinal != -1 && !(1..=4).contains(&value.ordinal)) {
        return None;
    }
    let target = if value.weekday == 1 {
        7
    } else {
        value.weekday as u32 - 1
    };
    if value.ordinal == -1 {
        let last = month.at_end();
        let back = (last.iso_weekday() + 7 - target) % 7;
        return Some(last.plus_days(-i64::from(back)));
    }
    let first = month.at_day(1)?;
    let offset = (target + 7 - first.iso_weekday()) % 7;
    let day = 1 + offset + (value.ordinal as u32 - 1) * 7;
    if day <= month.length() { month.at_day(day) } else { None }
}
