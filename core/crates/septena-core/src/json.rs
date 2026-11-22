//! One JSON entry point for hosts without typed bindings (the WASM package for
//! the web client and the Worker). Input and output are JSON objects with the
//! same camelCase keys as the conformance vectors.

use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::CoreError;
use crate::{
    ConversationProjection, FadeInput, OrdinalWeekday, PullPageHeader, PushOutcome, RecurrenceRule, ReminderArmInput,
    TaskConversation, TaskSnapshot, TaskViewMembership, check_pull_page, conversation_state, derive_conversation, fade_fill,
    next_scheduled_date, occurrence_id, plan_pull_row, plan_push_response, row_opacity, server_rejection_reason,
    shift_reminder_for_recurrence, shift_reminder_on_reschedule, should_arm_reminder, should_fade,
    task_view_membership,
};

/// The functions `invoke_json` accepts.
pub const JSON_FUNCTIONS: &[&str] = &[
    "rowOpacity",
    "shouldFade",
    "fadeFill",
    "taskViewMembership",
    "nextScheduledDate",
    "occurrenceId",
    "shiftReminderForRecurrence",
    "shiftReminderOnReschedule",
    "shouldArmReminder",
    "deriveConversation",
    "conversationState",
    "checkPullPage",
    "planPullRow",
    "planPushResponse",
    "serverRejectionReason",
];

/// Calls one core function by name with a JSON object and returns its result
/// as JSON. A plan or decision comes back in the vectors' JSON shape; a core
/// error comes back as `{"error": "<message>"}` so hosts can log it as data.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn invoke_json(function: String, input_json: String) -> Result<String, CoreError> {
    let input: Value = serde_json::from_str(&input_json)
        .map_err(|e| CoreError::invalid(format!("Input for {function} is not JSON: {e}")))?;
    let output = match invoke_value(&function, input) {
        Ok(value) => value,
        Err(error @ CoreError::InvalidInput { .. }) if function_exists(&function) => json!({ "error": error.message() }),
        Err(error) => return Err(error),
    };
    Ok(output.to_string())
}

fn function_exists(name: &str) -> bool {
    JSON_FUNCTIONS.contains(&name)
}

pub(crate) fn invoke_value(function: &str, input: Value) -> Result<Value, CoreError> {
    let parse = |what: &str| -> CoreError { CoreError::invalid(format!("Input for {function} is not valid: {what}")) };
    match function {
        "rowOpacity" => {
            let fill = input.get("fill").and_then(Value::as_f64);
            Ok(json!(row_opacity(fill)))
        }
        "shouldFade" => Ok(json!(should_fade(decode::<FadeInput>(input).map_err(|e| parse(&e))?)?)),
        "fadeFill" => Ok(json!(fade_fill(decode::<FadeInput>(input).map_err(|e| parse(&e))?)?)),
        "taskViewMembership" => {
            let args: ViewArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(membership_json(&task_view_membership(args.task, args.today, args.now)?))
        }
        "nextScheduledDate" => {
            let args: NextScheduledArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(json!(args.run()))
        }
        "occurrenceId" => {
            let args: OccurrenceArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(json!(occurrence_id(args.source_task_id, args.scheduled)))
        }
        "shiftReminderForRecurrence" => {
            let args: ShiftRecurrenceArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(json!(shift_reminder_for_recurrence(args.source_reminder_at, args.source_scheduled, args.next_scheduled)))
        }
        "shiftReminderOnReschedule" => {
            let args: ShiftRescheduleArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(json!(shift_reminder_on_reschedule(args.reminder_at, args.old_scheduled, args.new_scheduled)))
        }
        "shouldArmReminder" => Ok(json!(should_arm_reminder(decode::<ReminderArmInput>(input).map_err(|e| parse(&e))?))),
        "deriveConversation" => {
            let args: ConvoArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(projection_json(&derive_conversation(args.conversation, args.now)?))
        }
        "conversationState" => {
            let args: ConvoArgs = decode(input).map_err(|e| parse(&e))?;
            serde_json::to_value(conversation_state(args.conversation, args.now)?)
                .map_err(|e| CoreError::invalid(e.to_string()))
        }
        "checkPullPage" => {
            let args: PullPageArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(check_pull_page(args.cursor, args.page, args.resets_so_far).to_json())
        }
        "planPullRow" => {
            let args: PullRowArgs = decode(input).map_err(|e| parse(&e))?;
            if !args.row.is_object() {
                return Err(CoreError::invalid("Pulled row is not a JSON object"));
            }
            let current = match args.current {
                Some(Value::Null) | None => None,
                Some(value) => Some(value.to_string()),
            };
            Ok(plan_pull_row(args.entity, args.row.to_string(), current, args.pending_fields, args.pending_delete)?
                .to_json())
        }
        "planPushResponse" => {
            let args: PushArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(plan_push_response(args.sent_ids, args.outcome).to_json())
        }
        "serverRejectionReason" => {
            let args: RejectionArgs = decode(input).map_err(|e| parse(&e))?;
            Ok(json!(server_rejection_reason(args.status, args.body)))
        }
        other => Err(CoreError::invalid(format!("Unknown core function: {other}"))),
    }
}

fn decode<T: for<'de> Deserialize<'de>>(input: Value) -> Result<T, String> {
    serde_json::from_value(input).map_err(|e| e.to_string())
}

pub(crate) fn membership_json(m: &TaskViewMembership) -> Value {
    json!({
        "isUnfiled": m.is_unfiled,
        "isInboxMember": m.is_inbox_member,
        "inTriageBand": m.in_triage_band,
        "isOnToday": m.is_on_today,
        "inInbox": m.in_today_inbox,
        "daysOnToday": m.days_on_today,
        "matchesView": {
            "today": m.matches_today,
            "inbox": m.matches_inbox,
            "upcoming": m.matches_upcoming,
            "anytime": m.matches_anytime,
        },
    })
}

pub(crate) fn projection_json(p: &ConversationProjection) -> Value {
    json!({
        "stage": p.stage,
        "badge": p.badge,
        "nextAction": p.next_action,
        "pendingReasoning": p.pending_reasoning,
    })
}

#[derive(Deserialize)]
pub(crate) struct ViewArgs {
    pub task: TaskSnapshot,
    pub today: String,
    pub now: String,
}

/// The flat shape of `recurrence.json` inputs.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NextScheduledArgs {
    pub completed_on: String,
    #[serde(default)]
    pub scheduled: Option<String>,
    #[serde(default)]
    pub logical_scheduled: Option<String>,
    pub unit: String,
    #[serde(default)]
    pub interval: Option<i32>,
    #[serde(default)]
    pub after_completion: Option<bool>,
    #[serde(default)]
    pub weekdays: Option<Vec<i32>>,
    #[serde(default)]
    pub month_day: Option<i32>,
    #[serde(default)]
    pub ordinal_weekday: Option<OrdinalWeekday>,
}

impl NextScheduledArgs {
    pub(crate) fn run(self) -> Option<String> {
        next_scheduled_date(
            self.completed_on,
            self.scheduled,
            self.logical_scheduled,
            RecurrenceRule {
                unit: self.unit,
                interval: self.interval.unwrap_or(1),
                after_completion: self.after_completion.unwrap_or(true),
                weekdays: self.weekdays,
                month_day: self.month_day,
                ordinal_weekday: self.ordinal_weekday,
            },
        )
    }
}

#[derive(Deserialize)]
pub(crate) struct OccurrenceArgs {
    #[serde(rename = "sourceTaskID", alias = "sourceTaskId")]
    pub source_task_id: String,
    pub scheduled: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ShiftRecurrenceArgs {
    #[serde(default)]
    pub source_reminder_at: Option<String>,
    #[serde(default)]
    pub source_scheduled: Option<String>,
    #[serde(default)]
    pub next_scheduled: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ShiftRescheduleArgs {
    #[serde(default)]
    pub reminder_at: Option<String>,
    #[serde(default)]
    pub old_scheduled: Option<String>,
    #[serde(default)]
    pub new_scheduled: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct ConvoArgs {
    #[serde(alias = "convo")]
    pub conversation: TaskConversation,
    pub now: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PullPageArgs {
    pub cursor: i64,
    pub page: PullPageHeader,
    #[serde(default)]
    pub resets_so_far: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PullRowArgs {
    pub entity: String,
    pub row: Value,
    #[serde(default)]
    pub current: Option<Value>,
    #[serde(default)]
    pub pending_fields: Vec<String>,
    #[serde(default)]
    pub pending_delete: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PushArgs {
    pub sent_ids: Vec<String>,
    pub outcome: PushOutcome,
}

#[derive(Deserialize)]
pub(crate) struct RejectionArgs {
    pub status: u16,
    pub body: String,
}
