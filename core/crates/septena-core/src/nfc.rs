//! Unicode Normalization Form C, for the iCloud path of a `file:` reference.
//! Own code: the `unicode-normalization` crate put the native slices over
//! their size budget (`docs/SHARED_CORE_SPEC.md` §6).

use crate::nfc_table::{CLASSES, CLASSES_WIDE, COMPOSE, COMPOSE_WIDE, DECOMPOSE, DECOMPOSE_WIDE};

const S_BASE: u32 = 0xAC00;
const L_BASE: u32 = 0x1100;
const V_BASE: u32 = 0x1161;
const T_BASE: u32 = 0x11A7;
const L_COUNT: u32 = 19;
const V_COUNT: u32 = 21;
const T_COUNT: u32 = 28;
const S_COUNT: u32 = L_COUNT * V_COUNT * T_COUNT;

pub(crate) fn nfc(text: &str) -> String {
    // No character below U+0300 changes.
    if text.chars().all(|c| u32::from(c) < 0x300) {
        return text.to_string();
    }
    let mut chars: Vec<(u32, u8)> = Vec::new();
    for c in text.chars() {
        decompose(u32::from(c), &mut chars);
    }
    // Canonical order: a stable insertion sort inside each run of marks.
    for i in 1..chars.len() {
        let mut j = i;
        while j > 0 && chars[j].1 > 0 && chars[j - 1].1 > chars[j].1 {
            chars.swap(j - 1, j);
            j -= 1;
        }
    }
    let mut out: Vec<u32> = Vec::new();
    let mut starter: Option<usize> = None;
    let mut last_class = 0;
    for (c, class) in chars {
        if let Some(at) = starter
            && (at + 1 == out.len() || last_class < class)
            && let Some(joined) = compose(out[at], c)
        {
            out[at] = joined;
            continue;
        }
        if class == 0 {
            starter = Some(out.len());
        }
        out.push(c);
        last_class = class;
    }
    out.into_iter().filter_map(char::from_u32).collect()
}

fn decompose(c: u32, out: &mut Vec<(u32, u8)>) {
    if (S_BASE..S_BASE + S_COUNT).contains(&c) {
        let s = c - S_BASE;
        out.push((L_BASE + s / (V_COUNT * T_COUNT), 0));
        out.push((V_BASE + s % (V_COUNT * T_COUNT) / T_COUNT, 0));
        if !s.is_multiple_of(T_COUNT) {
            out.push((T_BASE + s % T_COUNT, 0));
        }
        return;
    }
    let Some((first, second)) = parts(c) else {
        out.push((c, class(c)));
        return;
    };
    decompose(first, out);
    if second != 0 {
        decompose(second, out);
    }
}

/// The canonical decomposition of one character. `second` is 0 when there is
/// only one part.
fn parts(c: u32) -> Option<(u32, u32)> {
    match u16::try_from(c) {
        Ok(c) => [COMPOSE, DECOMPOSE].into_iter().find_map(|table| {
            let at = table.binary_search_by_key(&c, |row| row.0).ok()?;
            Some((u32::from(table[at].1), u32::from(table[at].2)))
        }),
        Err(_) => [COMPOSE_WIDE, DECOMPOSE_WIDE].into_iter().find_map(|table| {
            let at = table.binary_search_by_key(&c, |row| row.0).ok()?;
            Some((table[at].1, table[at].2))
        }),
    }
}

fn class(c: u32) -> u8 {
    match u16::try_from(c) {
        Ok(c) => {
            let at = CLASSES.partition_point(|row| row.1 < c);
            CLASSES.get(at).filter(|row| row.0 <= c).map_or(0, |row| row.2)
        }
        Err(_) => {
            let at = CLASSES_WIDE.partition_point(|row| row.1 < c);
            CLASSES_WIDE.get(at).filter(|row| row.0 <= c).map_or(0, |row| row.2)
        }
    }
}

fn compose(a: u32, b: u32) -> Option<u32> {
    if (L_BASE..L_BASE + L_COUNT).contains(&a) && (V_BASE..V_BASE + V_COUNT).contains(&b) {
        return Some(S_BASE + ((a - L_BASE) * V_COUNT + (b - V_BASE)) * T_COUNT);
    }
    let syllable = (S_BASE..S_BASE + S_COUNT).contains(&a) && (a - S_BASE).is_multiple_of(T_COUNT);
    if syllable && (T_BASE + 1..T_BASE + T_COUNT).contains(&b) {
        return Some(a + (b - T_BASE));
    }
    match (u16::try_from(a), u16::try_from(b)) {
        (Ok(a), Ok(b)) => {
            let row = COMPOSE.iter().find(|row| row.1 == a && row.2 == b)?;
            Some(u32::from(row.0))
        }
        _ => {
            let row = COMPOSE_WIDE.iter().find(|row| row.1 == a && row.2 == b)?;
            Some(row.0)
        }
    }
}
