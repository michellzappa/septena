//! Reusable project rows. The host supplies live rows in project order,
//! including heading rows. The core returns ids so hosts retain their rows.

use serde_json::{Value, json};

use crate::error::CoreError;
use crate::nfc::{nfc, strip_marks};
use crate::registry::enums::{task_kind, task_status};

pub const CHECKED: &str = "checklistChecked";

pub(crate) fn project_checklist(input: &Value) -> Result<Value, CoreError> {
    let rows = input["rows"]
        .as_array()
        .ok_or_else(|| CoreError::invalid("projectChecklist requires rows"))?;
    let mut headings = Vec::new();
    let mut active = Vec::new();
    let mut checked = Vec::new();
    let mut exact = Vec::new();
    let mut prefix = Vec::new();
    let query = input["query"].as_str().map(search_key).unwrap_or_default();

    for row in rows {
        if !row["deletedAt"].is_null() {
            continue;
        }
        if row["kind"] == task_kind::HEADING {
            headings.push(row);
        } else if row["status"] == task_status::OPEN || row["status"] == CHECKED {
            if row["status"] == CHECKED {
                checked.push(&row["id"]);
            } else {
                active.push(row);
            }
            if !query.is_empty() {
                let title = search_key(row["title"].as_str().unwrap_or(""));
                if title == query {
                    exact.push(&row["id"]);
                } else if title.starts_with(&query) || title.split_whitespace().any(|word| word.starts_with(&query)) {
                    prefix.push(&row["id"]);
                }
            }
        }
    }

    let ungrouped: Vec<_> = active
        .iter()
        .filter(|row| !headings.iter().any(|heading| heading["id"] == row["heading"]))
        .map(|row| &row["id"])
        .collect();
    let mut groups = Vec::new();
    for heading in headings {
        let items: Vec<_> = active
            .iter()
            .filter(|row| row["heading"] == heading["id"])
            .map(|row| &row["id"])
            .collect();
        if !items.is_empty() {
            groups.push(json!({ "id": heading["id"], "items": items }));
        }
    }
    exact.extend(prefix);
    let suggested_group = if input["groceries"] == true { grocery_group(&query) } else { None };
    Ok(json!({
        "ungrouped": ungrouped,
        "groups": groups,
        "checked": checked,
        "matches": exact,
        "suggestedGroup": suggested_group
    }))
}

fn search_key(text: &str) -> String {
    strip_marks(&nfc(text.trim())).to_ascii_lowercase()
}

fn grocery_group(item: &str) -> Option<&'static str> {
    const GROUPS: [(&str, &str); 6] = [
        (
            "produce",
            "apple|apples|avocado|banana|bananas|carrots|garlic|lettuce|onions|potatoes|spinach|tomato|tomatoes",
        ),
        ("dairy", "butter|cheese|eggs|greek yogurt|milk|oat milk|yogurt"),
        ("bakery", "bagels|bread|buns|rolls"),
        ("meatSeafood", "beef|chicken|pork|salmon|shrimp"),
        ("pantry", "coffee|flour|oats|olive oil|pasta|rice|salt|sugar|tea"),
        ("frozen", "frozen berries|frozen peas|frozen pizza|ice cream"),
    ];
    GROUPS
        .iter()
        .find(|(_, items)| items.split('|').any(|word| word == item))
        .map(|(group, _)| *group)
}

pub(crate) fn checklist_check_patch(checked: bool) -> Value {
    if !checked {
        return json!({ "status": task_status::OPEN });
    }
    let mut patch = serde_json::Map::new();
    for key in [
        "todaySetOn",
        "todayPosition",
        "scheduled",
        "deadline",
        "deferredDeadline",
        "startTime",
        "durationMinutes",
        "timeZone",
        "reminderAt",
        "reminderMode",
        "reminderSnoozedUntil",
        "reminderDismissedAt",
    ] {
        patch.insert(key.into(), Value::Null);
    }
    patch.insert("status".into(), Value::String(CHECKED.into()));
    patch.insert("today".into(), Value::Bool(false));
    Value::Object(patch)
}
