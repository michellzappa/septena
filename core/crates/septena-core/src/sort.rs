//! List sort: the order of a task list when the user picks a sort other than
//! Manual (`docs/LIST_SORT_SPEC.md`). Vectors: `list-sort.json`.
//!
//! The host passes the tasks of ONE group (one heading, one list group) in
//! manual order. The sort is stable, so manual order breaks every tie. A task
//! without the sorted field sinks below the tasks that have it. The sort never
//! changes a stored position: picking Manual again shows the manual order.

use std::cmp::Ordering;

use crate::date::{Day, parse_instant_ms};
use crate::error::CoreError;
use crate::nfc::{nfc, strip_marks};
use crate::registry::enums::list_sort;
use crate::views::{TaskSnapshot, parse_day};

/// The task ids of `tasks` in the order of `sort` (a `listSort` enum value).
/// Hosts call it through `invoke_json("sortTasks", …)`: a typed FFI export
/// would put the native slices over their size budget.
pub fn sort_tasks(tasks: Vec<TaskSnapshot>, sort: String) -> Result<Vec<String>, CoreError> {
    let mut rows: Vec<&TaskSnapshot> = tasks.iter().collect();
    match sort.as_str() {
        list_sort::MANUAL => {}
        list_sort::WHEN => rows.sort_by(|a, b| soonest_first(parse_day(&a.scheduled), parse_day(&b.scheduled))),
        list_sort::DEADLINE => rows.sort_by(|a, b| soonest_first(parse_day(&a.deadline), parse_day(&b.deadline))),
        list_sort::TITLE => {
            let mut keyed: Vec<(TitleKey, &TaskSnapshot)> =
                rows.into_iter().map(|t| (title_key(&t.title), t)).collect();
            keyed.sort_by(|a, b| match (a.0.full.is_empty(), b.0.full.is_empty()) {
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                _ => a.0.base.cmp(&b.0.base).then_with(|| a.0.full.cmp(&b.0.full)),
            });
            rows = keyed.into_iter().map(|(_, t)| t).collect();
        }
        list_sort::CREATED => rows.sort_by(|a, b| newest_first(created_ms(a), created_ms(b))),
        other => return Err(CoreError::invalid(format!("`sort` is not a list sort: {other}"))),
    }
    Ok(rows.into_iter().map(|t| t.id.clone()).collect())
}

/// Earlier day first; no day last.
fn soonest_first(a: Option<Day>, b: Option<Day>) -> Ordering {
    match (a, b) {
        (Some(x), Some(y)) => x.cmp(&y),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

/// Later instant first; no instant last.
fn newest_first(a: Option<i64>, b: Option<i64>) -> Ordering {
    match (a, b) {
        (Some(x), Some(y)) => y.cmp(&x),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

/// `createdAt`, else the start of the `created` day in UTC.
fn created_ms(task: &TaskSnapshot) -> Option<i64> {
    task.created_at
        .as_deref()
        .and_then(parse_instant_ms)
        .or_else(|| parse_day(&task.created).map(|d| d.start_ms(0)))
}

/// A title compared without case. `base` also ignores accents, so "École"
/// sorts next to "ecole", not after "zebra"; `full` orders the two. Case
/// folding is ASCII after the accents come off, which covers Latin letters.
/// Full Unicode case tables would put the native slices over budget.
struct TitleKey {
    base: String,
    full: String,
}

fn title_key(title: &str) -> TitleKey {
    let full = nfc(title.trim());
    TitleKey {
        base: strip_marks(&full).to_ascii_lowercase(),
        full: full.to_ascii_lowercase(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(id: &str, title: &str) -> TaskSnapshot {
        TaskSnapshot {
            id: id.into(),
            title: title.into(),
            status: "open".into(),
            ..Default::default()
        }
    }

    #[test]
    fn manual_keeps_input_order() {
        let out = sort_tasks(vec![task("b", "B"), task("a", "A")], "manual".into()).unwrap();
        assert_eq!(out, vec!["b", "a"]);
    }

    #[test]
    fn unknown_sort_is_an_error() {
        assert!(sort_tasks(vec![], "priority".into()).is_err());
    }
}
