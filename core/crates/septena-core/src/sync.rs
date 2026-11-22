//! Sync decisions with no I/O (`docs/SHARED_CORE_SPEC.md` §3.1). The host
//! owns the store and the transport; the core decides what to do with each
//! pull page, each pulled row and each push response.
//! Vectors: `sync-engine.json`.

use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::error::CoreError;
use crate::registry::entity_names;

/// Keys of a pulled row that are server metadata, not entity fields.
const ROW_METADATA_KEYS: [&str; 4] = ["id", "rev", "updatedAt", "deletedAt"];
const TURN_ENTITY: &str = "turn";

// MARK: Pull pages

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct PullPageHeader {
    pub reset_required: bool,
    pub next_since: i64,
    pub has_more: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PullPageDecision {
    /// Apply the page and its cursor in one transaction; the pull is done.
    Apply,
    /// Apply the page, then pull again from `next_cursor`.
    ApplyAndContinue { next_cursor: i64 },
    /// Clear the remote cache and cursor, keep local rows and queued ops, pull from 0.
    Reset,
    /// Stop the sync and surface the reason.
    Fail { reason: String },
}

/// Checks one pull page against the stored cursor. A reset is allowed once
/// per sync (`resets_so_far` counts the earlier ones).
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn check_pull_page(cursor: i64, page: PullPageHeader, resets_so_far: u32) -> PullPageDecision {
    if page.reset_required {
        return if resets_so_far == 0 {
            PullPageDecision::Reset
        } else {
            PullPageDecision::Fail { reason: "Server requested another sync reset from revision 0".into() }
        };
    }
    if page.next_since < cursor {
        return PullPageDecision::Fail { reason: "Sync cursor moved backwards".into() };
    }
    if page.has_more && page.next_since <= cursor {
        return PullPageDecision::Fail { reason: "Sync pull made no progress while more pages remain".into() };
    }
    if page.has_more {
        PullPageDecision::ApplyAndContinue { next_cursor: page.next_since }
    } else {
        PullPageDecision::Apply
    }
}

impl PullPageDecision {
    pub fn to_json(&self) -> Value {
        match self {
            PullPageDecision::Apply => json!({ "decision": "apply" }),
            PullPageDecision::ApplyAndContinue { next_cursor } => {
                json!({ "decision": "applyAndContinue", "nextCursor": next_cursor })
            }
            PullPageDecision::Reset => json!({ "decision": "reset" }),
            PullPageDecision::Fail { reason } => json!({ "decision": "fail", "reason": reason }),
        }
    }
}

// MARK: Pulled rows

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PullRowPlan {
    /// Store the turn under its task id and sequence.
    Turn { task_id: String, seq: i64, row_json: String },
    /// A setting tombstone: keep the local setting.
    Skip,
    /// The server deleted the row. Reject every queued op for it. A task keeps
    /// its local fields with `deleted_at` set (`keep_local_row`); any other
    /// row is deleted locally. `revision` and `updated_at` are none when the
    /// server sent none: the host keeps its own.
    Tombstone {
        keep_local_row: bool,
        shadow_json: String,
        revision: Option<i64>,
        updated_at: Option<String>,
        deleted_at: String,
    },
    /// A local delete is queued: record the server snapshot only.
    ShadowOnly { shadow_json: String, revision: Option<i64> },
    /// Write the merged fields and the shadow. A field with a queued local op
    /// keeps its local value.
    Merge { fields_json: String, shadow_json: String, revision: Option<i64>, updated_at: Option<String> },
}

/// Plans the local write for one pulled row. `row_json` is the row as the
/// server sent it. `current_fields_json` is the local row's fields, or none
/// when the row is new. `pending_fields` are the fields with a queued upsert;
/// `pending_delete` is true when a delete of the row is queued.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn plan_pull_row(
    entity: String,
    row_json: String,
    current_fields_json: Option<String>,
    pending_fields: Vec<String>,
    pending_delete: bool,
) -> Result<PullRowPlan, CoreError> {
    let row = parse_object(&row_json, "Pulled row")?;
    if entity == TURN_ENTITY {
        let task_id = row
            .get("taskId")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::invalid("Pulled turn is missing taskId"))?;
        let seq = row.get("seq").and_then(Value::as_i64).ok_or_else(|| CoreError::invalid("Pulled turn is missing seq"))?;
        return Ok(PullRowPlan::Turn { task_id: task_id.to_string(), seq, row_json: Value::Object(row.clone()).to_string() });
    }
    if row.get("id").and_then(Value::as_str).is_none() {
        return Err(CoreError::invalid(format!("Pulled {entity} row is missing id")));
    }
    let revision = row.get("rev").and_then(Value::as_i64);
    let updated_at = row.get("updatedAt").and_then(Value::as_str).map(str::to_string);
    let tombstone = row.get("deletedAt").and_then(Value::as_str).map(str::to_string);
    let server_fields: Map<String, Value> =
        row.iter().filter(|(key, _)| !ROW_METADATA_KEYS.contains(&key.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect();
    let shadow_json = Value::Object(server_fields.clone()).to_string();
    let current = current_fields_json.as_deref().map(|raw| parse_object(raw, "Current fields")).transpose()?;

    if let Some(deleted_at) = tombstone {
        if entity == entity_names::SETTING {
            return Ok(PullRowPlan::Skip);
        }
        return Ok(PullRowPlan::Tombstone {
            keep_local_row: entity == entity_names::TASK && current.is_some(),
            shadow_json,
            revision,
            updated_at,
            deleted_at,
        });
    }
    if pending_delete {
        return Ok(PullRowPlan::ShadowOnly { shadow_json, revision });
    }
    let mut merged = current.unwrap_or_default();
    for (key, value) in server_fields {
        if !pending_fields.contains(&key) {
            merged.insert(key, value);
        }
    }
    Ok(PullRowPlan::Merge { fields_json: Value::Object(merged).to_string(), shadow_json, revision, updated_at })
}

impl PullRowPlan {
    pub fn to_json(&self) -> Value {
        let object = |raw: &str| serde_json::from_str::<Value>(raw).unwrap_or(Value::Null);
        match self {
            PullRowPlan::Turn { task_id, seq, row_json } => {
                json!({ "plan": "turn", "taskId": task_id, "seq": seq, "row": object(row_json) })
            }
            PullRowPlan::Skip => json!({ "plan": "skip" }),
            PullRowPlan::Tombstone { keep_local_row, shadow_json, revision, updated_at, deleted_at } => json!({
                "plan": "tombstone",
                "keepLocalRow": keep_local_row,
                "shadow": object(shadow_json),
                "revision": revision,
                "updatedAt": updated_at,
                "deletedAt": deleted_at,
            }),
            PullRowPlan::ShadowOnly { shadow_json, revision } => {
                json!({ "plan": "shadowOnly", "shadow": object(shadow_json), "revision": revision })
            }
            PullRowPlan::Merge { fields_json, shadow_json, revision, updated_at } => json!({
                "plan": "merge",
                "fields": object(fields_json),
                "shadow": object(shadow_json),
                "revision": revision,
                "updatedAt": updated_at,
            }),
        }
    }
}

// MARK: Push responses

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum PushOutcome {
    /// The server answered; `result_ids` are the client op ids of its results, in order.
    Response { result_ids: Vec<String> },
    /// The transport failed with an HTTP status.
    HttpFailure { status: u16, body: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PushPlan {
    /// Apply the server's results to the outbox.
    ApplyResults,
    /// Move this one op to Not synced with the reason.
    RejectOne { client_op_id: String, reason: String },
    /// Push `sent[..split_at]` and `sent[split_at..]` separately.
    Bisect { split_at: u32 },
    /// Not a validation failure: hand the status to the host's retry and backoff.
    Propagate { status: u16 },
    /// Stop the sync and surface the reason.
    Fail { reason: String },
}

/// Decides what a push response means for the batch that was sent.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn plan_push_response(sent_ids: Vec<String>, outcome: PushOutcome) -> PushPlan {
    match outcome {
        PushOutcome::Response { result_ids } => {
            if result_ids == sent_ids {
                PushPlan::ApplyResults
            } else {
                PushPlan::Fail { reason: "Push response did not match the submitted operation order".into() }
            }
        }
        PushOutcome::HttpFailure { status, body } => {
            if status != 400 {
                return PushPlan::Propagate { status };
            }
            match sent_ids.len() {
                0 => PushPlan::Fail { reason: "No operations were sent".into() },
                1 => PushPlan::RejectOne {
                    client_op_id: sent_ids[0].clone(),
                    reason: server_rejection_reason(status, body),
                },
                n => PushPlan::Bisect { split_at: (n / 2) as u32 },
            }
        }
    }
}

impl PushPlan {
    pub fn to_json(&self) -> Value {
        match self {
            PushPlan::ApplyResults => json!({ "plan": "applyResults" }),
            PushPlan::RejectOne { client_op_id, reason } => {
                json!({ "plan": "rejectOne", "clientOpId": client_op_id, "reason": reason })
            }
            PushPlan::Bisect { split_at } => json!({ "plan": "bisect", "splitAt": split_at }),
            PushPlan::Propagate { status } => json!({ "plan": "propagate", "status": status }),
            PushPlan::Fail { reason } => json!({ "plan": "fail", "reason": reason }),
        }
    }
}

/// The text the Not synced list shows for a rejected op: the validation
/// issues, else `message`, else `error`, else the body, else the status.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn server_rejection_reason(status: u16, body: String) -> String {
    let body = body.trim();
    let root = serde_json::from_str::<Value>(body).ok().and_then(|v| match v {
        Value::Object(map) => Some(map),
        _ => None,
    });
    let issues: Vec<String> = root
        .as_ref()
        .and_then(|r| r.get("issues"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let fields = item.as_object()?;
                    let message = fields.get("message")?.as_str()?;
                    let path: Vec<String> = fields
                        .get("path")
                        .and_then(Value::as_array)
                        .map(|parts| {
                            parts
                                .iter()
                                .filter_map(|part| match part {
                                    Value::String(s) => Some(s.clone()),
                                    Value::Number(n) if n.is_i64() || n.is_u64() => Some(n.to_string()),
                                    _ => None,
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    Some(if path.is_empty() { message.to_string() } else { format!("{}: {message}", path.join(".")) })
                })
                .collect()
        })
        .unwrap_or_default();
    if !issues.is_empty() {
        return issues.join("; ");
    }
    let field = |name: &str| root.as_ref().and_then(|r| r.get(name)).and_then(Value::as_str).map(str::to_string);
    field("message")
        .or_else(|| field("error"))
        .or_else(|| (!body.is_empty()).then(|| body.to_string()))
        .unwrap_or_else(|| format!("The server rejected this operation with HTTP {status}"))
}

fn parse_object(raw: &str, what: &str) -> Result<Map<String, Value>, CoreError> {
    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Object(map)) => Ok(map),
        _ => Err(CoreError::invalid(format!("{what} is not a JSON object"))),
    }
}
