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
    /// An agent added the task and the user has not accepted it (ADR 0039).
    #[serde(default)]
    pub is_proposal: bool,
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
    /// The conversation's end state. A tracked task (`decomposed`, ADR 0065)
    /// is in no working list, so it never fades.
    #[serde(default)]
    #[cfg_attr(feature = "ffi", uniffi(default = None))]
    pub end_state: Option<String>,
}

/// Row opacity for a fade fill in 0…1. No fill, or a fill at or below 0, is opaque.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn row_opacity(fill: Option<f64>) -> f64 {
    match fill {
        Some(fill) if fill.is_finite() && fill > 0.0 => 1.0 - fill.min(1.0) * (1.0 - rules::FADE_MIN_OPACITY),
        _ => 1.0,
    }
}

/// Proposals made before this instant keep the old rule: they aged in as
/// ordinary tasks before expiry shipped (#499).
const PROPOSALS_EXPIRE_SINCE: &str = "2026-11-26T00:00:00Z";

/// True when the task has gone untouched for the whole fade window, or is a
/// proposal that the user left alone for the cue window (ADR 0039).
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn should_fade(input: FadeInput) -> Result<bool, CoreError> {
    let now = instant(&input.now, "now")?;
    let today = day(&input.today, "today")?;
    if proposal_expired(&input, now) {
        return Ok(true);
    }
    if !is_eligible(&input, today) {
        return Ok(false);
    }
    let Some(clock) = clock_ms(&input) else {
        return Ok(false);
    };
    Ok(now - clock >= rules::FADE_WINDOW_DAYS * MS_PER_DAY)
}

/// The fade fill in 0…1 after the grace period, or none when the task shows
/// no fade (not eligible, an agent cue, or still in grace).
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn fade_fill(input: FadeInput) -> Result<Option<f64>, CoreError> {
    let now = instant(&input.now, "now")?;
    let today = day(&input.today, "today")?;
    if input.shows_agent_cue || !is_eligible(&input, today) {
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

/// An unanswered proposal expires with or without a date (ADR 0039): silence
/// never accepts. A touch accepts it, and it is an ordinary task from then on.
fn proposal_expired(input: &FadeInput, now: i64) -> bool {
    if !input.is_proposal || input.touched_at.is_some() || !is_candidate(input) {
        return false;
    }
    let Some(made) = clock_ms(input) else { return false };
    let since = parse_instant_ms(PROPOSALS_EXPIRE_SINCE).unwrap_or(0);
    made >= since && now - made >= rules::CUE_DECAY_DAYS * MS_PER_DAY
}

/// Open, in a list, and waiting on nobody.
fn is_candidate(input: &FadeInput) -> bool {
    input.is_open
        && !input.is_heading
        && !input.is_deleted
        && !input.is_faded
        && !input.is_agent_turn
        && !input.is_assigned_to_claude
        && !input.is_awaiting_human
        && input.end_state.as_deref() != Some(crate::registry::enums::convo_end_state::DECOMPOSED)
}

fn is_eligible(input: &FadeInput, today: Day) -> bool {
    if !is_candidate(input) {
        return false;
    }
    if input.deadline.as_deref().and_then(Day::parse).is_some() {
        return false;
    }
    // A When date today or later holds the task. An invalid day reads as no
    // date (invariant I3).
    if input
        .scheduled
        .as_deref()
        .and_then(Day::parse)
        .is_some_and(|d| d >= today)
    {
        return false;
    }
    !input.has_recurrence
}

fn clock_ms(input: &FadeInput) -> Option<i64> {
    input
        .touched_at
        .as_deref()
        .and_then(parse_instant_ms)
        .or_else(|| input.created_at.as_deref().and_then(parse_instant_ms))
        .or_else(|| {
            input
                .created
                .as_deref()
                .and_then(Day::parse)
                .map(|d| d.start_ms(input.utc_offset_seconds))
        })
}

pub(crate) fn instant(raw: &str, name: &str) -> Result<i64, CoreError> {
    parse_instant_ms(raw).ok_or_else(|| CoreError::invalid(format!("`{name}` is not an ISO-8601 instant: {raw}")))
}

pub(crate) fn day(raw: &str, name: &str) -> Result<Day, CoreError> {
    Day::parse(raw).ok_or_else(|| CoreError::invalid(format!("`{name}` is not a YYYY-MM-DD date: {raw}")))
}
