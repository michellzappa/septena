//! Reusable project rows. The host supplies live rows in project order,
//! including heading rows. The core returns ids so hosts retain their rows.

use serde_json::{Value, json};

use crate::error::CoreError;
use crate::nfc::{nfc, strip_marks};
use crate::recurrence::occurrence_id;
use crate::registry::enums::{task_kind, task_status};

pub const CHECKED: &str = "checklistChecked";

pub(crate) fn project_checklist(input: &Value) -> Result<Value, CoreError> {
    let rows = input["rows"]
        .as_array()
        .ok_or_else(|| CoreError::invalid("projectChecklist requires rows"))?;
    let mut headings = Vec::new();
    let mut active = Vec::new();
    let mut checked = Vec::new();
    let mut checked_headings = Vec::new();
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
                checked_headings.push(&row["heading"]);
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
        // A heading shows while it has active rows, and also while it has no
        // rows at all (a section the user just made). Only a heading whose
        // rows are all checked (an aisle that is done) leaves the active list.
        let all_checked = items.is_empty() && checked_headings.iter().any(|h| **h == heading["id"]);
        if !all_checked {
            groups.push(json!({ "id": heading["id"], "items": items }));
        }
    }
    exact.extend(prefix);
    let suggested_group = if input["groceries"] == true {
        grocery_group(&query)
    } else {
        None
    };
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

/// The offline grocery vocabulary. The keys are the registry's
/// `checklistProjects.groups`, which hold the heading titles.
const GROCERY_GROUPS: [(&str, &str); 6] = [
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

fn grocery_group(item: &str) -> Option<&'static str> {
    GROCERY_GROUPS
        .iter()
        .find(|(_, items)| items.split('|').any(|word| word == item))
        .map(|(group, _)| *group)
}

/// The stable id of a suggested group heading in one project. Two offline
/// devices that add the same grocery create the same heading row.
pub(crate) fn checklist_heading_id(project_id: &str, group: &str) -> String {
    occurrence_id(format!("checklist:{project_id}"), group.to_string())
}

/// Decides which heading a new row joins for a suggested group. The host
/// passes the project's rows (deleted rows included) and the localized title
/// of the group. Returns `{ heading, create }`:
/// 1. a live heading with the stable id, else a live heading with the same
///    title (case- and accent-insensitive): reuse it;
/// 2. a deleted heading with the stable id or the same title: the user
///    removed that group, so the row stays ungrouped;
/// 3. else: create a heading with the stable id and the title.
pub(crate) fn checklist_heading(input: &Value) -> Result<Value, CoreError> {
    let none = json!({ "heading": null, "create": false });
    let project = input["projectId"].as_str().unwrap_or("");
    let group = input["group"].as_str().unwrap_or("");
    let title = search_key(input["title"].as_str().unwrap_or(""));
    if project.is_empty() || group.is_empty() || title.is_empty() {
        return Ok(none);
    }
    let rows = input["rows"]
        .as_array()
        .ok_or_else(|| CoreError::invalid("checklistHeading requires rows"))?;
    let id = checklist_heading_id(project, group);
    let headings: Vec<&Value> = rows
        .iter()
        .filter(|row| row["kind"] == task_kind::HEADING)
        .filter(|row| row["project"].is_null() || row["project"] == project)
        .collect();
    let has_id = |row: &Value| row["id"] == id.as_str();
    let has_title = |row: &Value| search_key(row["title"].as_str().unwrap_or("")) == title;
    let live = |row: &Value| row["deletedAt"].is_null();
    let reuse = headings
        .iter()
        .copied()
        .find(|row| live(row) && has_id(row))
        .or_else(|| headings.iter().copied().find(|row| live(row) && has_title(row)));
    if let Some(row) = reuse {
        return Ok(json!({ "heading": row["id"], "create": false }));
    }
    if headings.iter().any(|row| !live(row) && (has_id(row) || has_title(row))) {
        return Ok(none);
    }
    Ok(json!({ "heading": id, "create": true }))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::checklist_groups;

    #[test]
    fn grocery_keys_match_the_registry() {
        let keys: Vec<_> = GROCERY_GROUPS.iter().map(|(key, _)| *key).collect();
        assert_eq!(keys, checklist_groups::KEYS);
    }
}
