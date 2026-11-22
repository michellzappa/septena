//! Conversation projection for task rows and the agent queue (ADR 0008).
//! Vectors: `convo-derived.json`.

use serde::{Deserialize, Serialize};

use crate::date::parse_instant_ms;
use crate::error::CoreError;
use crate::fade::instant;
use crate::registry::enums::{convo_assignee, convo_end_state, convo_turn_role};

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ConversationTurn {
    #[serde(rename = "seq")]
    pub sequence: i64,
    pub role: String,
    #[serde(default)]
    pub options: Option<Vec<String>>,
    #[serde(default)]
    pub confidence: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase", default)]
pub struct TaskConversation {
    pub confirmed_intent: Option<String>,
    pub thread: Vec<ConversationTurn>,
    pub artifact_exists: bool,
    pub handoff_exists: bool,
    pub end_state: Option<String>,
    pub end_state_note: Option<String>,
    pub assignee: Option<String>,
    pub stopped_at: Option<String>,
    pub claim_until: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct ConversationProjection {
    /// `open`, `clarifying`, `inProgress`, `awaitingHuman` or `terminal`.
    pub stage: String,
    /// `needsYou`, `working`, `done`, `wontDo` or none.
    pub badge: Option<String>,
    pub next_action: String,
    pub pending_reasoning: bool,
}

/// Projects a conversation onto its row stage and badge. `now` decides
/// whether a claim is still live.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn derive_conversation(conversation: TaskConversation, now: String) -> Result<ConversationProjection, CoreError> {
    let now = instant(&now, "now")?;
    let mut thread = conversation.thread.clone();
    thread.sort_by_key(|turn| turn.sequence);

    let is_terminal = conversation.end_state.as_deref().is_some_and(|s| s != convo_end_state::OPEN);
    let needs_review = conversation.end_state.as_deref() == Some(convo_end_state::NEEDS_VERIFY);
    let open_question = thread
        .last()
        .is_some_and(|t| t.role == convo_turn_role::PROVIDER && t.options.as_ref().is_some_and(|o| !o.is_empty()));
    let has_started = !thread.is_empty()
        || conversation.confirmed_intent.is_some()
        || is_terminal
        || conversation.artifact_exists
        || conversation.handoff_exists;
    let pending = if is_terminal || conversation.stopped_at.is_some() {
        false
    } else if conversation.assignee.as_deref() == Some(convo_assignee::CLAUDE) {
        true
    } else {
        thread
            .iter()
            .rev()
            .find(|t| t.role == convo_turn_role::PROVIDER)
            .and_then(|t| t.confidence)
            .is_some_and(|c| c < 0.5)
    };
    let note = |fallback: &str| conversation.end_state_note.clone().unwrap_or_else(|| fallback.to_string());
    let projection = |stage: &str, badge: Option<&str>, next_action: String, pending_reasoning: bool| {
        ConversationProjection {
            stage: stage.to_string(),
            badge: badge.map(str::to_string),
            next_action,
            pending_reasoning,
        }
    };

    if needs_review {
        return Ok(projection("awaitingHuman", Some("needsYou"), note("Needs review"), false));
    }
    if is_terminal {
        let badge = if conversation.end_state.as_deref() == Some(convo_end_state::WONT_DO) { "wontDo" } else { "done" };
        return Ok(projection("terminal", Some(badge), note("Resolved"), false));
    }
    if !has_started {
        return Ok(projection("open", None, "No conversation yet".into(), pending));
    }
    if conversation.stopped_at.is_some() {
        return Ok(projection("inProgress", None, "Stopped".into(), false));
    }
    if open_question {
        return Ok(projection("awaitingHuman", Some("needsYou"), "Tap to answer".into(), pending));
    }
    let stage = if conversation.confirmed_intent.is_none() { "clarifying" } else { "inProgress" };
    let claimed = conversation.claim_until.as_deref().and_then(parse_instant_ms).is_some_and(|until| until > now);
    let next = if claimed { "Claude is working" } else { "Claude's move" };
    Ok(projection(stage, Some("working"), next.into(), pending))
}
