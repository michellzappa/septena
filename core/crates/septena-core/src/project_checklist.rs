//! Reusable project rows. The host supplies live rows in project order,
//! including heading rows. The core returns ids so hosts retain their rows.

use serde::Deserialize;
use serde_json::{Value, json};

use crate::nfc::{nfc, strip_marks};
use crate::registry::enums::{task_kind, task_status};

pub const CHECKED: &str = "checklistChecked";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ChecklistRow {
    id: String,
    title: String,
    status: String,
    kind: Option<String>,
    heading: Option<String>,
    deleted_at: Option<String>,
}

pub(crate) fn project_checklist(rows: Vec<ChecklistRow>, query: Option<String>, groceries: bool) -> Value {
    let mut headings = Vec::new();
    let mut active = Vec::new();
    let mut checked = Vec::new();
    let mut exact = Vec::new();
    let mut prefix = Vec::new();
    let query = query.as_deref().map(search_key).unwrap_or_default();

    for row in &rows {
        if row.deleted_at.is_some() {
            continue;
        }
        if row.kind.as_deref() == Some(task_kind::HEADING) {
            headings.push(row);
        } else if row.status == task_status::OPEN || row.status == CHECKED {
            if row.status == CHECKED {
                checked.push(&row.id);
            } else {
                active.push(row);
            }
            if !query.is_empty() {
                let title = search_key(&row.title);
                if title == query {
                    exact.push(&row.id);
                } else if title.starts_with(&query) || title.split_whitespace().any(|word| word.starts_with(&query)) {
                    prefix.push(&row.id);
                }
            }
        }
    }

    let ungrouped: Vec<_> = active
        .iter()
        .filter(|row| !headings.iter().any(|heading| Some(&heading.id) == row.heading.as_ref()))
        .map(|row| &row.id)
        .collect();
    let mut groups = Vec::new();
    for heading in headings {
        let items: Vec<_> = active
            .iter()
            .filter(|row| row.heading.as_ref() == Some(&heading.id))
            .map(|row| &row.id)
            .collect();
        if !items.is_empty() {
            groups.push(json!({ "id": heading.id, "items": items }));
        }
    }
    exact.extend(prefix);
    let suggested_group = if groceries { grocery_group(&query) } else { None };
    json!({
        "ungrouped": ungrouped,
        "groups": groups,
        "checked": checked,
        "matches": exact,
        "suggestedGroup": suggested_group
    })
}

fn search_key(text: &str) -> String {
    strip_marks(&nfc(text.trim())).to_ascii_lowercase()
}

fn grocery_group(item: &str) -> Option<&'static str> {
    Some(match item {
        "apple" | "apples" | "avocado" | "banana" | "bananas" | "carrots" | "garlic" | "lettuce" | "onions"
        | "potatoes" | "spinach" | "tomato" | "tomatoes" => "produce",
        "butter" | "cheese" | "eggs" | "greek yogurt" | "milk" | "oat milk" | "yogurt" => "dairy",
        "bagels" | "bread" | "buns" | "rolls" => "bakery",
        "beef" | "chicken" | "pork" | "salmon" | "shrimp" => "meatSeafood",
        "coffee" | "flour" | "oats" | "olive oil" | "pasta" | "rice" | "salt" | "sugar" | "tea" => "pantry",
        "frozen berries" | "frozen peas" | "frozen pizza" | "ice cream" => "frozen",
        _ => return None,
    })
}

pub(crate) fn checklist_check_patch(checked: bool) -> Value {
    if !checked {
        return json!({ "status": task_status::OPEN });
    }
    json!({
        "status": CHECKED,
        "today": false,
        "todaySetOn": null,
        "todayPosition": null,
        "scheduled": null,
        "deadline": null,
        "deferredDeadline": null,
        "startTime": null,
        "durationMinutes": null,
        "timeZone": null,
        "reminderAt": null,
        "reminderMode": null,
        "reminderSnoozedUntil": null,
        "reminderDismissedAt": null
    })
}
