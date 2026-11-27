//! List sort: the order of a task list when the user picks a sort other than
//! Manual (`docs/LIST_SORT_SPEC.md`). Vectors: `list-sort.json`.
//!
//! The host passes the tasks of ONE group (one heading, one list group) in
//! manual order. The sort is stable, so manual order breaks every tie. A task
//! without the sorted field sinks below the tasks that have it. The sort never
//! changes a stored position: picking Manual again shows the manual order.

use crate::date::{Day, parse_instant_ms};
use crate::error::CoreError;
use crate::nfc::{nfc, strip_marks};
use crate::registry::enums::list_sort;
use crate::views::{TaskSnapshot, parse_day};

/// The task ids of `tasks` in the order of `sort` (a `listSort` enum value).
/// Hosts call it through `invoke_json("sortTasks", …)`: a typed FFI export
/// would put the native slices over their size budget.
pub fn sort_tasks(tasks: Vec<TaskSnapshot>, sort: String) -> Result<Vec<String>, CoreError> {
    let key: fn(&TaskSnapshot) -> Key = match sort.as_str() {
        list_sort::MANUAL => return Ok(tasks.into_iter().map(|t| t.id).collect()),
        list_sort::WHEN => |t| Key::day(parse_day(&t.scheduled)),
        list_sort::DEADLINE => |t| Key::day(parse_day(&t.deadline)),
        list_sort::TITLE => |t| Key::title(&t.title),
        // Newest first: a later instant has a smaller key.
        list_sort::CREATED => |t| Key::number(created_ms(t).map(|ms| -ms)),
        other => return Err(CoreError::invalid(format!("`sort` is not a list sort: {other}"))),
    };
    let keys: Vec<Key> = tasks.iter().map(key).collect();
    Ok(stable_order(&keys).into_iter().map(|i| tasks[i].id.clone()).collect())
}

/// What one task sorts by. A missing value sorts after every present one.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    missing: bool,
    number: i64,
    /// The title without case and accents, so "École" sorts next to "ecole".
    base: String,
    /// The title without case: orders "Pera" before "Pêra".
    full: String,
}

impl Key {
    fn number(value: Option<i64>) -> Key {
        Key {
            missing: value.is_none(),
            number: value.unwrap_or_default(),
            base: String::new(),
            full: String::new(),
        }
    }

    fn day(day: Option<Day>) -> Key {
        Key::number(day.map(Day::days))
    }

    /// Case folding is ASCII after the accents come off, which covers Latin
    /// letters. Full Unicode case tables would put the native slices over
    /// budget.
    fn title(title: &str) -> Key {
        let full = nfc(title.trim());
        Key {
            missing: full.is_empty(),
            number: 0,
            base: strip_marks(&full).to_ascii_lowercase(),
            full: full.to_ascii_lowercase(),
        }
    }
}

/// Indices of `keys` in ascending order, ties in input order. A binary
/// insertion sort: one small loop instead of another instance of the
/// standard library's sort, which costs native slice size per comparator.
fn stable_order(keys: &[Key]) -> Vec<usize> {
    let mut order: Vec<usize> = Vec::with_capacity(keys.len());
    for i in 0..keys.len() {
        let at = order.partition_point(|&j| keys[j] <= keys[i]);
        order.insert(at, i);
    }
    order
}

/// `createdAt`, else the start of the `created` day in UTC.
fn created_ms(task: &TaskSnapshot) -> Option<i64> {
    task.created_at
        .as_deref()
        .and_then(parse_instant_ms)
        .or_else(|| parse_day(&task.created).map(|d| d.start_ms(0)))
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
