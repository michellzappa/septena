//! Task fade (ADR 0006, `docs/TASK_FADE_SPEC.md`). Vectors: `task-fade.json`.

use serde::Deserialize;

use crate::date::{Day, MS_PER_DAY, parse_instant_ms};
use crate::error::CoreError;
use crate::registry::rules;

/// The facts about one task that fade reads. `now` is an ISO-8601 instant and
/// `today` is `YYYY-MM-DD`, both from the host's day clock. `utc_offset_seconds`
/// places a date-only `created` value on the host's clock.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct FadeInput {
    pub is_open: bool,
    pub is_heading: bool,
    pub is_deleted: bool,
    pub is_faded: bool,
    #[serde(default)]
    pub deadline: Option<String>,
    #[serde(default)]
    pub scheduled: Option<String>,
    pub has_recurrence: bool,
    pub is_agent_turn: bool,
    pub is_assigned_to_claude: bool,
    #[serde(default)]
    pub is_awaiting_human: bool,
    #[serde(default)]
    pub shows_agent_cue: bool,
    #[serde(default)]
    pub touched_at: Option<String>,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub created: Option<String>,
    pub now: String,
    pub today: String,
    #[serde(default)]
    pub utc_offset_seconds: i32,
}

/// Row opacity for a fade fill in 0…1. No fill, or a fill at or below 0, is opaque.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn row_opacity(fill: Option<f64>) -> f64 {
    match fill {
        Some(fill) if fill.is_finite() && fill > 0.0 => 1.0 - fill.min(1.0) * (1.0 - rules::FADE_MIN_OPACITY),
        _ => 1.0,
    }
}

/// True when the task has gone untouched for the whole fade window.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn should_fade(input: FadeInput) -> Result<bool, CoreError> {
    let now = instant(&input.now, "now")?;
    if !is_eligible(&input) {
        return Ok(false);
    }
    let Some(clock) = clock_ms(&input) else { return Ok(false) };
    Ok(now - clock >= rules::FADE_WINDOW_DAYS * MS_PER_DAY)
}

/// The fade fill in 0…1 after the grace period, or none when the task shows
/// no fade (not eligible, an agent cue, or still in grace).
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn fade_fill(input: FadeInput) -> Result<Option<f64>, CoreError> {
    let now = instant(&input.now, "now")?;
    if input.shows_agent_cue || !is_eligible(&input) {
        return Ok(None);
    }
    let Some(clock) = clock_ms(&input) else { return Ok(None) };
    let elapsed = now - clock;
    if elapsed < rules::FADE_GRACE_DAYS * MS_PER_DAY {
        return Ok(None);
    }
    let window = (rules::FADE_WINDOW_DAYS * MS_PER_DAY) as f64;
    Ok(Some((elapsed as f64 / window).min(1.0)))
}

fn is_eligible(input: &FadeInput) -> bool {
    if !input.is_open || input.is_heading || input.is_deleted || input.is_faded {
        return false;
    }
    if input.deadline.as_deref().is_some_and(|d| !d.is_empty()) {
        return false;
    }
    if let Some(scheduled) = input.scheduled.as_deref().filter(|s| !s.is_empty()) {
        let head: String = scheduled.chars().take(10).collect();
        if head.as_str() >= input.today.as_str() {
            return false;
        }
    }
    !input.has_recurrence && !input.is_agent_turn && !input.is_assigned_to_claude && !input.is_awaiting_human
}

fn clock_ms(input: &FadeInput) -> Option<i64> {
    input
        .touched_at
        .as_deref()
        .and_then(parse_instant_ms)
        .or_else(|| input.created_at.as_deref().and_then(parse_instant_ms))
        .or_else(|| input.created.as_deref().and_then(Day::parse).map(|d| d.start_ms(input.utc_offset_seconds)))
}

pub(crate) fn instant(raw: &str, name: &str) -> Result<i64, CoreError> {
    parse_instant_ms(raw).ok_or_else(|| CoreError::invalid(format!("`{name}` is not an ISO-8601 instant: {raw}")))
}

pub(crate) fn day(raw: &str, name: &str) -> Result<Day, CoreError> {
    Day::parse(raw).ok_or_else(|| CoreError::invalid(format!("`{name}` is not a YYYY-MM-DD date: {raw}")))
}
