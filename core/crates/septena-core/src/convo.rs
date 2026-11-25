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

/// The facts about a conversation that task lists and the Agent list read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct ConversationState {
    pub is_terminal: bool,
    /// An agent handed the task back for the human to verify (`needs_verify`).
    pub needs_human_review: bool,
    /// The last turn is a provider turn with options and no answer yet.
    pub has_open_provider_question: bool,
    pub awaits_human: bool,
    pub has_started: bool,
    /// A live claim: `claim_until` is after `now`. The host passes
    /// `claim_until` only when the claim has a claimant.
    pub is_claimed: bool,
    /// The Agent smart list stage (`queued`, `working`, `yourTurn`, `stopped`,
    /// `review`, `done`), or none when the task is not agent work.
    pub agent_stage: Option<String>,
}

/// The predicates and the Agent-list stage of a conversation
/// (`docs/TASK_FACTORY_SPEC.md` §3). Review and Done win over a stale
/// assignee; a stop wins over an open question, because only the human can
/// resume it (ADR 0008).
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn conversation_state(conversation: TaskConversation, now: String) -> Result<ConversationState, CoreError> {
    let now = instant(&now, "now")?;
    let facts = Facts::of(&conversation, now);
    let agent_stage =
        if conversation.assignee.as_deref() != Some(convo_assignee::CLAUDE) && !facts.is_claimed && !facts.needs_review
        {
            None
        } else if facts.needs_review {
            Some("review")
        } else if facts.is_terminal {
            Some("done")
        } else if conversation.stopped_at.is_some() {
            Some("stopped")
        } else if facts.open_question {
            Some("yourTurn")
        } else if facts.is_claimed {
            Some("working")
        } else {
            Some("queued")
        };
    Ok(ConversationState {
        is_terminal: facts.is_terminal,
        needs_human_review: facts.needs_review,
        has_open_provider_question: facts.open_question,
        awaits_human: facts.needs_review || facts.open_question,
        has_started: facts.has_started,
        is_claimed: facts.is_claimed,
        agent_stage: agent_stage.map(str::to_string),
        review_group: if facts.needs_review {
            Some("finished".to_string())
        } else if facts.open_question && conversation.stopped_at.is_none() {
            Some("questions".to_string())
        } else {
            None
        },
    })
}

struct Facts {
    is_terminal: bool,
    needs_review: bool,
    open_question: bool,
    has_started: bool,
    is_claimed: bool,
}

impl Facts {
    fn of(conversation: &TaskConversation, now: i64) -> Facts {
        let last = conversation.thread.iter().max_by_key(|turn| turn.sequence);
        let is_terminal = conversation
            .end_state
            .as_deref()
            .is_some_and(|s| s != convo_end_state::OPEN);
        Facts {
            is_terminal,
            needs_review: conversation.end_state.as_deref() == Some(convo_end_state::NEEDS_VERIFY),
            open_question: last.is_some_and(|t| {
                t.role == convo_turn_role::PROVIDER && t.options.as_ref().is_some_and(|o| !o.is_empty())
            }),
            has_started: !conversation.thread.is_empty()
                || conversation.confirmed_intent.is_some()
                || is_terminal
                || conversation.artifact_exists
                || conversation.handoff_exists,
            is_claimed: conversation
                .claim_until
                .as_deref()
                .and_then(parse_instant_ms)
                .is_some_and(|until| until > now),
        }
    }
}

/// Projects a conversation onto its row stage and badge. `now` decides
/// whether a claim is still live.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn derive_conversation(conversation: TaskConversation, now: String) -> Result<ConversationProjection, CoreError> {
    let now = instant(&now, "now")?;
    let mut thread = conversation.thread.clone();
    thread.sort_by_key(|turn| turn.sequence);

    let is_terminal = conversation
        .end_state
        .as_deref()
        .is_some_and(|s| s != convo_end_state::OPEN);
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
    let note = |fallback: &str| {
        conversation
            .end_state_note
            .clone()
            .unwrap_or_else(|| fallback.to_string())
    };
    let projection =
        |stage: &str, badge: Option<&str>, next_action: String, pending_reasoning: bool| ConversationProjection {
            stage: stage.to_string(),
            badge: badge.map(str::to_string),
            next_action,
            pending_reasoning,
        };

    if needs_review {
        return Ok(projection(
            "awaitingHuman",
            Some("needsYou"),
            note("Needs review"),
            false,
        ));
    }
    if is_terminal {
        let badge = if conversation.end_state.as_deref() == Some(convo_end_state::WONT_DO) {
            "wontDo"
        } else {
            "done"
        };
        return Ok(projection("terminal", Some(badge), note("Resolved"), false));
    }
    if !has_started {
        return Ok(projection("open", None, "No conversation yet".into(), pending));
    }
    if conversation.stopped_at.is_some() {
        return Ok(projection("inProgress", None, "Stopped".into(), false));
    }
    if open_question {
        return Ok(projection(
            "awaitingHuman",
            Some("needsYou"),
            "Tap to answer".into(),
            pending,
        ));
    }
    let stage = if conversation.confirmed_intent.is_none() {
        "clarifying"
    } else {
        "inProgress"
    };
    let claimed = conversation
        .claim_until
        .as_deref()
        .and_then(parse_instant_ms)
        .is_some_and(|until| until > now);
    let next = if claimed { "Claude is working" } else { "Claude's move" };
    Ok(projection(stage, Some("working"), next.into(), pending))
}
