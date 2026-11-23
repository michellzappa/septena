//! Runs one `registry/conformance/*.json` file inside the core, through the
//! same JSON entry point the WASM package uses. Each packaged harness (Swift,
//! JVM, WASM) calls this with the file's text, so the vectors run in every
//! artifact, on every platform.

use serde::Serialize;
use serde_json::{Value, json};

use crate::error::CoreError;
use crate::json::invoke_value;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ConformanceReport {
    pub fixture: String,
    pub cases: u32,
    /// One line per failed case: `<section>/<name>: expected …, got …`.
    pub failures: Vec<String>,
}

/// The fixtures the core runs, by file name without `.json`.
pub const CONFORMANCE_FIXTURES: &[&str] = &[
    "convo-derived",
    "recurrence",
    "reminders",
    "sync-engine",
    "task-dates",
    "task-fade",
    "task-views",
];

/// The `now` of `convo-derived.json`, which has no clock of its own. No case
/// carries a claim, so the value only has to parse.
const CONVO_NOW: &str = "2026-11-20T12:00:00Z";

/// Runs every case of one fixture file.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn run_conformance(fixture: String, json: String) -> Result<ConformanceReport, CoreError> {
    let doc: Value =
        serde_json::from_str(&json).map_err(|e| CoreError::invalid(format!("{fixture}.json is not JSON: {e}")))?;
    let mut run = Run {
        fixture: fixture.clone(),
        cases: 0,
        failures: Vec::new(),
    };
    match fixture.as_str() {
        "task-fade" => {
            for case in cases(&doc, "rowOpacity") {
                run.check("rowOpacity", case, "rowOpacity", json!({ "fill": case["fill"] }), false);
            }
            for case in cases(&doc, "shouldFade") {
                run.check("shouldFade", case, "shouldFade", case["input"].clone(), false);
            }
        }
        "task-views" => {
            for case in cases(&doc, "cases") {
                let input = json!({ "task": case["task"], "today": doc["today"], "now": doc["nowIso"] });
                run.check("cases", case, "taskViewMembership", input, false);
            }
        }
        "task-dates" => {
            let today = &doc["today"];
            let now = &doc["now"];
            for case in cases(&doc, "actions") {
                let input = json!({ "task": case["task"], "action": case["action"], "today": today, "now": now });
                run.check("actions", case, "applyDateAction", input, false);
            }
            for case in cases(&doc, "normalize") {
                let input = json!({ "task": case["task"], "today": today });
                run.check("normalize", case, "normalizeTaskDates", input, false);
            }
            for case in cases(&doc, "nextOccurrence") {
                let input = json!({ "task": case["task"], "nextScheduled": case["nextScheduled"], "now": now });
                run.check("nextOccurrence", case, "nextOccurrenceDates", input, false);
            }
        }
        "recurrence" => {
            for case in cases(&doc, "nextScheduledDate") {
                run.check(
                    "nextScheduledDate",
                    case,
                    "nextScheduledDate",
                    case["input"].clone(),
                    false,
                );
            }
            for case in cases(&doc, "occurrenceID") {
                let input = json!({ "sourceTaskID": case["sourceTaskID"], "scheduled": case["scheduled"] });
                run.check("occurrenceID", case, "occurrenceId", input, false);
            }
        }
        "reminders" => {
            for section in [
                "shiftReminderForRecurrence",
                "shiftReminderOnReschedule",
                "shouldArmReminder",
            ] {
                for case in cases(&doc, section) {
                    run.check(section, case, section, case["input"].clone(), false);
                }
            }
        }
        "convo-derived" => {
            for case in cases(&doc, "cases") {
                let input = json!({ "conversation": case["convo"], "now": CONVO_NOW });
                run.check("cases", case, "deriveConversation", input, true);
            }
            for case in cases(&doc, "conversationState") {
                let now = case.get("now").cloned().unwrap_or_else(|| json!(CONVO_NOW));
                let input = json!({ "conversation": case["convo"], "now": now });
                run.check("conversationState", case, "conversationState", input, false);
            }
        }
        "sync-engine" => {
            for (section, function) in [
                ("pullPage", "checkPullPage"),
                ("pullRow", "planPullRow"),
                ("pushResponse", "planPushResponse"),
                ("rejectionReason", "serverRejectionReason"),
            ] {
                for case in cases(&doc, section) {
                    run.check(section, case, function, case["input"].clone(), false);
                }
            }
        }
        other => {
            return Err(CoreError::invalid(format!(
                "The core has no runner for conformance fixture {other}"
            )));
        }
    }
    if run.cases == 0 {
        run.failures
            .push(format!("{}: the fixture has no cases the core knows", run.fixture));
    }
    Ok(ConformanceReport {
        fixture: run.fixture,
        cases: run.cases,
        failures: run.failures,
    })
}

struct Run {
    fixture: String,
    cases: u32,
    failures: Vec<String>,
}

impl Run {
    fn check(&mut self, section: &str, case: &Value, function: &str, input: Value, subset: bool) {
        self.cases += 1;
        let name = case.get("name").and_then(Value::as_str).unwrap_or("(unnamed)");
        let expected = case.get("expected").cloned().unwrap_or(Value::Null);
        let actual = match invoke_value(function, input) {
            Ok(value) => value,
            Err(error) => json!({ "error": error.message() }),
        };
        if !matches(&expected, &actual, subset) {
            self.failures
                .push(format!("{section}/{name}: expected {expected}, got {actual}"));
        }
    }
}

fn cases<'a>(doc: &'a Value, section: &str) -> impl Iterator<Item = &'a Value> {
    doc.get(section).and_then(Value::as_array).into_iter().flatten()
}

/// JSON equality with a float tolerance. With `subset`, only the keys of
/// `expected` are compared at the top level.
fn matches(expected: &Value, actual: &Value, subset: bool) -> bool {
    match (expected, actual) {
        (Value::Number(a), Value::Number(b)) => match (a.as_f64(), b.as_f64()) {
            (Some(x), Some(y)) => (x - y).abs() < 1e-9,
            _ => a == b,
        },
        (Value::Object(e), Value::Object(a)) => {
            if !subset && e.len() != a.len() {
                return false;
            }
            e.iter()
                .all(|(key, value)| a.get(key).is_some_and(|other| matches(value, other, false)))
        }
        (Value::Array(e), Value::Array(a)) => e.len() == a.len() && e.iter().zip(a).all(|(x, y)| matches(x, y, false)),
        _ => expected == actual,
    }
}
