//! Civil dates and ISO-8601 instants without a time-zone database. The host
//! supplies `today` and `now`; the core only does arithmetic.

pub(crate) const MS_PER_DAY: i64 = 86_400_000;

/// A proleptic Gregorian date, stored as days since 1970-01-01.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Day(i64);

impl Day {
    pub(crate) const EPOCH: Day = Day(0);

    pub(crate) fn from_ymd(year: i64, month: u32, day: u32) -> Option<Day> {
        if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
            return None;
        }
        Some(Day(days_from_civil(year, month, day)))
    }

    /// Parses the first 10 characters as `YYYY-MM-DD`, like `LocalDate.parse(s.take(10))`.
    pub(crate) fn parse(raw: &str) -> Option<Day> {
        let head: Vec<char> = raw.chars().take(10).collect();
        if head.len() != 10 || head[4] != '-' || head[7] != '-' {
            return None;
        }
        let year = digits(&head[0..4])?;
        let month = digits(&head[5..7])? as u32;
        let day = digits(&head[8..10])? as u32;
        Day::from_ymd(year, month, day)
    }

    pub(crate) fn days(self) -> i64 {
        self.0
    }

    pub(crate) fn ymd(self) -> (i64, u32, u32) {
        civil_from_days(self.0)
    }

    pub(crate) fn year(self) -> i64 {
        self.ymd().0
    }

    pub(crate) fn month(self) -> u32 {
        self.ymd().1
    }

    pub(crate) fn day_of_month(self) -> u32 {
        self.ymd().2
    }

    pub(crate) fn plus_days(self, days: i64) -> Day {
        Day(self.0 + days)
    }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    pub(crate) fn iso_weekday(self) -> u32 {
        ((self.0 + 3).rem_euclid(7) + 1) as u32
    }

    /// Milliseconds since the epoch at the start of this day, at a UTC offset.
    pub(crate) fn start_ms(self, utc_offset_seconds: i32) -> i64 {
        self.0 * MS_PER_DAY - i64::from(utc_offset_seconds) * 1000
    }
}

impl std::fmt::Display for Day {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (y, m, d) = self.ymd();
        write!(f, "{y:04}-{m:02}-{d:02}")
    }
}

/// A calendar month, for month and year recurrence steps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct YearMonth {
    pub(crate) year: i64,
    pub(crate) month: u32,
}

impl YearMonth {
    pub(crate) fn of(day: Day) -> YearMonth {
        let (year, month, _) = day.ymd();
        YearMonth { year, month }
    }

    pub(crate) fn plus_months(self, months: i64) -> YearMonth {
        let total = self.year * 12 + i64::from(self.month) - 1 + months;
        YearMonth {
            year: total.div_euclid(12),
            month: (total.rem_euclid(12) + 1) as u32,
        }
    }

    pub(crate) fn length(self) -> u32 {
        days_in_month(self.year, self.month)
    }

    pub(crate) fn at_day(self, day: u32) -> Option<Day> {
        Day::from_ymd(self.year, self.month, day)
    }

    pub(crate) fn at_end(self) -> Day {
        Day(days_from_civil(self.year, self.month, self.length()))
    }
}

pub(crate) fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

pub(crate) fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => 0,
    }
}

/// Parses an ISO-8601 instant (`2026-11-21T12:00:00Z`, optional seconds and
/// fraction, `Z` or `±HH:MM`) into milliseconds since the epoch.
pub(crate) fn parse_instant_ms(raw: &str) -> Option<i64> {
    let chars: Vec<char> = raw.trim().chars().collect();
    if chars.len() < 17 || !matches!(chars[10], 'T' | 't') || chars[13] != ':' {
        return None;
    }
    let day = Day::parse(&chars[0..10].iter().collect::<String>())?;
    let hour = digits(&chars[11..13])?;
    let minute = digits(&chars[14..16])?;
    if hour > 23 || minute > 59 {
        return None;
    }
    let mut index = 16;
    let mut second = 0;
    let mut millis = 0;
    if chars.get(index) == Some(&':') {
        second = digits(chars.get(index + 1..index + 3)?)?;
        if second > 59 {
            return None;
        }
        index += 3;
        if chars.get(index) == Some(&'.') {
            index += 1;
            let start = index;
            while chars.get(index).is_some_and(char::is_ascii_digit) {
                index += 1;
            }
            if index == start {
                return None;
            }
            let fraction: String = chars[start..index].iter().take(3).collect();
            let padded = format!("{fraction:0<3}");
            millis = padded.parse::<i64>().ok()?;
        }
    }
    let offset_seconds = match *chars.get(index)? {
        'Z' | 'z' if index + 1 == chars.len() => 0,
        sign @ ('+' | '-') => {
            let rest = &chars[index + 1..];
            let (hours, minutes) = match rest.len() {
                5 if rest[2] == ':' => (digits(&rest[0..2])?, digits(&rest[3..5])?),
                4 => (digits(&rest[0..2])?, digits(&rest[2..4])?),
                2 => (digits(&rest[0..2])?, 0),
                _ => return None,
            };
            let total = hours * 3600 + minutes * 60;
            if sign == '-' { -total } else { total }
        }
        _ => return None,
    };
    Some(day.days() * MS_PER_DAY + hour * 3_600_000 + minute * 60_000 + second * 1000 + millis - offset_seconds * 1000)
}

fn digits(chars: &[char]) -> Option<i64> {
    if chars.is_empty() || !chars.iter().all(char::is_ascii_digit) {
        return None;
    }
    chars.iter().collect::<String>().parse().ok()
}

// Howard Hinnant's civil-date algorithms.
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let m = i64::from(month);
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_days() {
        for raw in ["1970-01-01", "2000-02-29", "2026-11-21", "2028-02-29", "1969-12-31"] {
            assert_eq!(Day::parse(raw).unwrap().to_string(), raw);
        }
        assert_eq!(Day::parse("1970-01-01").unwrap().iso_weekday(), 4);
        assert_eq!(Day::parse("2026-11-23").unwrap().iso_weekday(), 1);
        assert!(Day::parse("2026-02-29").is_none());
    }

    #[test]
    fn parses_instants() {
        assert_eq!(parse_instant_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_instant_ms("1970-01-01T01:00:00+01:00"), Some(0));
        assert_eq!(parse_instant_ms("1970-01-01T00:00:00.250Z"), Some(250));
        assert_eq!(parse_instant_ms("1970-01-01T00:01Z"), Some(60_000));
        assert_eq!(parse_instant_ms("2026-11-21"), None);
    }
}
