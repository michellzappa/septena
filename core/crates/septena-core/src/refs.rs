//! Task references: the key grammar (`docs/TASK_REFERENCES_SPEC.md` §3, §6.1,
//! ADR 0031). Vectors: `refs.json`.
//!
//! A key is `<kind>:<id>`. Keys are stored for the life of the account, so a
//! change to the normal form of an existing kind needs a new ADR and a
//! migration. An error reason never holds the input: hosts may log it, and a
//! key is user content (§10).

use serde::{Deserialize, Serialize};

use crate::date::Day;
use crate::error::CoreError;
use crate::nfc::nfc;
use crate::recurrence::fnv1a64;
use crate::registry::limits;

const EMAIL: &str = "email";
const THREAD: &str = "thread";
const EVENT: &str = "event";
const ISSUE: &str = "issue";
const TASK: &str = "task";
const DOOR: &str = "door";
const URL: &str = "url";
const FILE: &str = "file";

const KIND_MAX: usize = 32;
const ROW_ID_MAX: usize = 128;
const GITHUB_PATH: &str = "github.com/";
const STARLINGS_SUFFIX: &str = ".starlings.work";

/// One parsed reference.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct ParsedRef {
    /// `<kind>:<id>` in normal form. The lookup key.
    pub key: String,
    pub kind: String,
    /// The part of `key` after the kind.
    pub id: String,
    /// The id before normalisation, for the resolver (`snapshot.rawId`). A
    /// Message-ID has no angle brackets and no white space here.
    pub raw_id: String,
    /// The web address of the item, when the input was one.
    pub url: Option<String>,
}

/// The headers of one message, as written in the message.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct MessageHeaders {
    #[serde(default)]
    pub message_id: Option<String>,
    #[serde(default)]
    pub in_reply_to: Option<String>,
    #[serde(default)]
    pub references: Option<String>,
}

/// How a message reached Septena.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
#[serde(rename_all = "camelCase")]
pub enum MailArrival {
    /// Sent to the account's forwarding address.
    Forwarded,
    /// Read in the mailbox by a feed or by an agent with mail access.
    Mailbox,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct EmailRefInput {
    pub arrival: MailArrival,
    /// The `From` address is the account owner.
    pub from_is_owner: bool,
    pub message: MessageHeaders,
    /// The headers of the `message/rfc822` part, when the message has one.
    #[serde(default)]
    pub attached: Option<MessageHeaders>,
}

/// The references of one captured message (§6.1). None means "no key".
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[serde(rename_all = "camelCase")]
pub struct EmailRefKeys {
    pub email: Option<ParsedRef>,
    pub thread: Option<ParsedRef>,
}

/// Parses a key, a web URL or a `message://` link.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn parse_ref(input: String) -> Result<ParsedRef, CoreError> {
    let input = input.trim();
    match scheme(input).as_deref() {
        Some("http" | "https") => web_ref(input),
        Some("message") => message_link_ref(input),
        _ => key_ref(input),
    }
}

/// The normal form of a key. A URL is not a key: use `parse_ref`.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn normalize_ref_key(key: String) -> Result<String, CoreError> {
    let key = key.trim();
    if matches!(scheme(key).as_deref(), Some("http" | "https" | "message")) {
        return Err(CoreError::invalid("A URL is not a reference key"));
    }
    Ok(key_ref(key)?.key)
}

/// Every GitHub issue or pull request URL in a text, in order, one per key.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn find_issue_refs(text: String) -> Vec<ParsedRef> {
    let mut found: Vec<ParsedRef> = Vec::new();
    // ASCII lower case keeps every byte offset.
    let lower = text.to_ascii_lowercase();
    let mut from = 0;
    while let Some(offset) = lower[from..].find(GITHUB_PATH) {
        let start = from + offset;
        from = start + GITHUB_PATH.len();
        let before = &lower[..start];
        let before = before.strip_suffix("www.").unwrap_or(before);
        if !before.ends_with("http://") && !before.ends_with("https://") {
            continue;
        }
        let Some(issue) = issue_in_path(&text[from..]) else {
            continue;
        };
        if found.iter().all(|other| other.key != issue.key) {
            found.push(issue);
        }
    }
    found
}

/// The keys of a captured message. A forwarded mail is a new message with its
/// own Message-ID, and that id is never the key of the original.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn email_ref_keys(input: EmailRefInput) -> EmailRefKeys {
    if input.arrival == MailArrival::Forwarded {
        if let Some(attached) = &input.attached {
            return message_keys(attached);
        }
        if input.from_is_owner {
            let references = header_ids(input.message.references.as_deref());
            let replied = header_ids(input.message.in_reply_to.as_deref());
            return EmailRefKeys {
                email: references
                    .last()
                    .or(replied.first())
                    .and_then(|id| message_ref(EMAIL, id)),
                thread: references.first().and_then(|id| message_ref(THREAD, id)),
            };
        }
    }
    message_keys(&input.message)
}

/// The id of a `taskRef` row: FNV-1a 64 over `"<task id>|<key>|<n>"`, where
/// `n` is the number of deleted rows with the same task and key. Two offline
/// devices that add the same reference mint the same id.
#[cfg_attr(feature = "ffi", uniffi::export)]
pub fn task_ref_id(task_id: String, key: String, deleted_count: u32) -> String {
    format!("ref-{}", fnv1a64(&format!("{task_id}|{key}|{deleted_count}")))
}

// MARK: Keys

fn scheme(input: &str) -> Option<String> {
    input.split_once(':').map(|(head, _)| head.to_ascii_lowercase())
}

fn key_ref(input: &str) -> Result<ParsedRef, CoreError> {
    let Some((kind, id)) = input.split_once(':') else {
        return Err(CoreError::invalid("Not a reference key, a web URL or a message link"));
    };
    let kind = kind.to_ascii_lowercase();
    if !valid_kind(&kind) {
        return Err(CoreError::invalid("The reference kind is not valid"));
    }
    let id = id.trim();
    match kind.as_str() {
        EMAIL | THREAD => message_id_ref(&kind, id),
        EVENT => event_ref(id),
        ISSUE => issue_key_ref(id),
        TASK => task_key_ref(id, None),
        DOOR => door_key_ref(id),
        URL => web_ref(id),
        FILE => file_key_ref(id),
        // An unknown kind is kept as written. `<scheme>://…` is a URL with a
        // scheme that no client opens, not a key.
        _ if id.starts_with("//") => Err(CoreError::invalid("The URL scheme is not supported")),
        _ => build(&kind, id.to_string(), id, None),
    }
}

/// A lowercase ASCII letter, then lowercase letters, digits, `_` or `-`.
fn valid_kind(kind: &str) -> bool {
    kind.len() <= KIND_MAX
        && kind.starts_with(|c: char| c.is_ascii_lowercase())
        && kind
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn build(kind: &str, id: String, raw_id: &str, url: Option<String>) -> Result<ParsedRef, CoreError> {
    if id.is_empty() {
        return Err(CoreError::invalid("The reference id is empty"));
    }
    if id.chars().any(char::is_control) {
        return Err(CoreError::invalid("The reference id has control characters"));
    }
    let key = format!("{kind}:{id}");
    // UTF-16 units: the length the wire schema and the other hosts count.
    if key.encode_utf16().count() as i64 > limits::REF_KEY_MAX {
        return Err(CoreError::invalid("The reference key is too long"));
    }
    Ok(ParsedRef {
        key,
        kind: kind.to_string(),
        id,
        raw_id: raw_id.to_string(),
        url,
    })
}

// MARK: Mail

fn message_id_ref(kind: &str, text: &str) -> Result<ParsedRef, CoreError> {
    let raw: String = text
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '<' && *c != '>')
        .collect();
    let id = match raw.rsplit_once('@') {
        Some((local, domain)) => format!("{local}@{}", domain.to_lowercase()),
        None => raw.clone(),
    };
    build(kind, id, &raw, None)
}

fn message_link_ref(input: &str) -> Result<ParsedRef, CoreError> {
    let rest = input.split_once(':').map_or("", |(_, rest)| rest);
    let rest = rest.strip_prefix("//").unwrap_or(rest);
    match percent_decode(rest) {
        Some(id) => message_id_ref(EMAIL, &id),
        None => Err(CoreError::invalid("The message link is not valid")),
    }
}

fn message_ref(kind: &str, id: &str) -> Option<ParsedRef> {
    message_id_ref(kind, id).ok()
}

/// The message's own id and the root of its thread.
fn message_keys(headers: &MessageHeaders) -> EmailRefKeys {
    let own = header_ids(headers.message_id.as_deref());
    let references = header_ids(headers.references.as_deref());
    let replied = header_ids(headers.in_reply_to.as_deref());
    let root = references.first().or(replied.first()).or(own.first());
    EmailRefKeys {
        email: own.first().and_then(|id| message_ref(EMAIL, id)),
        thread: root.and_then(|id| message_ref(THREAD, id)),
    }
}

/// The Message-IDs in a header value: every `<…>` group, or, in a header
/// without angle brackets, every word with an `@`.
fn header_ids(value: Option<&str>) -> Vec<String> {
    let value = value.unwrap_or_default();
    let groups: Vec<String> = value
        .split('<')
        .skip(1)
        .filter_map(|part| part.split_once('>'))
        .map(|(id, _)| id.to_string())
        .filter(|id| !id.trim().is_empty())
        .collect();
    if !groups.is_empty() {
        return groups;
    }
    value
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|word| word.contains('@'))
        .map(str::to_string)
        .collect()
}

// MARK: Events

fn event_ref(id: &str) -> Result<ParsedRef, CoreError> {
    let (uid, recurrence) = match id.split_once('|') {
        Some((uid, recurrence)) => (uid, Some(recurrence)),
        None => (id, None),
    };
    // Decode first, so that a key in normal form does not change. `%25` last:
    // it must not make a new escape.
    let uid = uid
        .trim()
        .replace("%7C", "|")
        .replace("%7c", "|")
        .replace("%25", "%")
        .replace('%', "%25")
        .replace('|', "%7C");
    if uid.is_empty() {
        return Err(CoreError::invalid("The reference id is empty"));
    }
    let normal = match recurrence {
        None => uid,
        Some(text) => match recurrence_id(text) {
            Some(date) => format!("{uid}|{date}"),
            None => return Err(CoreError::invalid("The recurrence id of the event is not valid")),
        },
    };
    build(EVENT, normal, id, None)
}

/// `YYYYMMDD` or `YYYYMMDDTHHMMSSZ`.
fn recurrence_id(text: &str) -> Option<String> {
    let text = text.trim().to_ascii_uppercase();
    let (date, time) = match text.split_once('T') {
        Some((date, time)) => (date, Some(time.strip_suffix('Z')?)),
        None => (text.as_str(), None),
    };
    let part = |text: &str, range: std::ops::Range<usize>| -> Option<u32> { text.get(range)?.parse().ok() };
    let digits = |text: &str, length: usize| text.len() == length && text.bytes().all(|b| b.is_ascii_digit());
    if !digits(date, 8) {
        return None;
    }
    Day::from_ymd(i64::from(part(date, 0..4)?), part(date, 4..6)?, part(date, 6..8)?)?;
    if let Some(time) = time {
        // 60 is a leap second.
        if !digits(time, 6) || part(time, 0..2)? > 23 || part(time, 2..4)? > 59 || part(time, 4..6)? > 60 {
            return None;
        }
    }
    Some(text)
}

// MARK: GitHub

fn issue_key_ref(id: &str) -> Result<ParsedRef, CoreError> {
    let parts = id
        .split_once('#')
        .and_then(|(path, number)| path.split_once('/').map(|(owner, repo)| (owner, repo, number)));
    match parts {
        Some((owner, repo, number)) => issue_ref(owner, repo, number, None),
        None => Err(CoreError::invalid("An issue key is owner/repo#number")),
    }
}

fn issue_ref(owner: &str, repo: &str, number: &str, url: Option<String>) -> Result<ParsedRef, CoreError> {
    let name = |text: &str| {
        text.contains(|c: char| c != '.')
            && text
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.' || c == '-')
    };
    let value = if number.bytes().all(|b| b.is_ascii_digit()) {
        number.parse::<u64>().unwrap_or(0)
    } else {
        0
    };
    if !name(owner) || !name(repo) || value == 0 {
        return Err(CoreError::invalid("An issue key is owner/repo#number"));
    }
    let id = format!("{}/{}#{value}", owner.to_ascii_lowercase(), repo.to_ascii_lowercase());
    build(ISSUE, id, &format!("{owner}/{repo}#{number}"), url)
}

/// The issue or pull request named by `owner/repo/(issues|pull)/<n>…`.
fn issue_in_path(path: &str) -> Option<ParsedRef> {
    let mut parts = path.splitn(4, '/');
    let (owner, repo, kind, tail) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    if kind != "issues" && kind != "pull" {
        return None;
    }
    let after = tail.trim_start_matches(|c: char| c.is_ascii_digit());
    let number = &tail[..tail.len() - after.len()];
    let url = format!("https://github.com/{owner}/{repo}/{kind}/{number}");
    issue_ref(owner, repo, number, Some(url)).ok()
}

// MARK: Septena and Starlings

fn task_key_ref(id: &str, url: Option<String>) -> Result<ParsedRef, CoreError> {
    let bad = || CoreError::invalid("A task key is a task id or host/id");
    let Some((host, rest)) = id.split_once('/') else {
        return if valid_row_id(id) {
            build(TASK, id.to_string(), id, url)
        } else {
            Err(bad())
        };
    };
    let host = workspace_host(host).ok_or_else(bad)?;
    if rest.is_empty() || rest.contains(|c: char| c == '/' || c.is_whitespace()) {
        return Err(bad());
    }
    build(TASK, format!("{host}/{rest}"), id, url)
}

fn door_key_ref(id: &str) -> Result<ParsedRef, CoreError> {
    match id.split_once('|') {
        Some((host, door)) => door_ref(host.trim(), door.trim(), None),
        None => Err(CoreError::invalid("A door key is host|door")),
    }
}

fn door_ref(host: &str, door: &str, url: Option<String>) -> Result<ParsedRef, CoreError> {
    let bad = || CoreError::invalid("A door key is host|door");
    let normal_host = workspace_host(host).ok_or_else(bad)?;
    let (kind, rest) = door.split_once(':').ok_or_else(bad)?;
    if !valid_kind(kind) || rest.is_empty() {
        return Err(bad());
    }
    match kind {
        ISSUE => issue_key_ref(rest),
        TASK => task_key_ref(&format!("{host}/{rest}"), url),
        _ => build(DOOR, format!("{normal_host}|{door}"), &format!("{host}|{door}"), url),
    }
}

/// A Starlings record page, by the path of its permalink.
fn starlings_ref(web: &WebUrl) -> Option<ParsedRef> {
    if web.port.is_some() || !web.host.ends_with(STARLINGS_SUFFIX) || web.host.len() == STARLINGS_SUFFIX.len() {
        return None;
    }
    let segments: Vec<String> = web.segments().map(percent_decode).collect::<Option<_>>()?;
    let segments: Vec<&str> = segments.iter().map(String::as_str).collect();
    let door = match segments.as_slice() {
        ["work", "issue", owner, repo, number] => return issue_ref(owner, repo, number, None).ok(),
        ["work", "task", id] => format!("{TASK}:{id}"),
        ["work", kind @ ("lead" | "project" | "organization" | "event"), id] => format!("subject:{kind}:{id}"),
        ["work", "contact", id] => format!("contact:{id}"),
        ["docs", "document", id] => format!("document:{id}"),
        ["calendar", "event", id] => format!("event:{id}"),
        ["team", "thread", id] => format!("thread:{id}"),
        _ => return None,
    };
    door_ref(&web.host, &door, Some(web.normal.clone())).ok()
}

fn workspace_host(text: &str) -> Option<String> {
    let (host, port) = split_port(text)?;
    Some(match port {
        Some(port) => format!("{host}:{port}"),
        None => host,
    })
}

/// The id pattern of a synced row (`registry/entities.json` `patterns.id`).
fn valid_row_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= ROW_ID_MAX
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == ':' || c == '-')
}

// MARK: Files

fn file_key_ref(id: &str) -> Result<ParsedRef, CoreError> {
    let bad = || CoreError::invalid("A file key is attachment/id or icloud/path");
    match id.split_once('/').ok_or_else(bad)? {
        ("attachment", row) if valid_row_id(row) => build(FILE, id.to_string(), id, None),
        ("icloud", path) => {
            let path = nfc(path.trim_matches('/'));
            // A path that leaves the user's iCloud Drive is not a reference.
            if path
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == "..")
            {
                return Err(bad());
            }
            build(FILE, format!("icloud/{path}"), id, None)
        }
        _ => Err(bad()),
    }
}

// MARK: Web URLs

struct WebUrl {
    host: String,
    /// The port, when it is not the scheme's default.
    port: Option<u16>,
    path: String,
    /// The whole URL in normal form.
    normal: String,
}

impl WebUrl {
    fn segments(&self) -> impl Iterator<Item = &str> {
        self.path.split('/').filter(|part| !part.is_empty())
    }
}

fn web_ref(input: &str) -> Result<ParsedRef, CoreError> {
    let Some(web) = parse_web_url(input) else {
        return Err(CoreError::invalid("The web URL is not valid"));
    };
    if web.port.is_none() && (web.host == "github.com" || web.host == "www.github.com") {
        let path: Vec<&str> = web.segments().collect();
        let whole_number = path
            .get(3)
            .is_some_and(|number| number.bytes().all(|b| b.is_ascii_digit()));
        if let Some(issue) = issue_in_path(&path.join("/")).filter(|_| whole_number) {
            return Ok(issue);
        }
    }
    if let Some(record) = starlings_ref(&web) {
        return Ok(record);
    }
    build(URL, web.normal.clone(), input, Some(web.normal))
}

/// None for another scheme, a URL with a user name or password, white space
/// or control characters, or a host that is not valid.
fn parse_web_url(input: &str) -> Option<WebUrl> {
    if input.contains(|c: char| c.is_whitespace() || c.is_control()) {
        return None;
    }
    let (scheme, rest) = input.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    let default_port = match scheme.as_str() {
        "http" => 80,
        "https" => 443,
        _ => return None,
    };
    let rest = rest.split('#').next().unwrap_or_default();
    let (authority, tail) = rest.split_at(rest.find(['/', '?']).unwrap_or(rest.len()));
    let (host, port) = split_port(authority)?;
    let port = port.filter(|port| *port != default_port);
    let (path, query) = tail.split_once('?').unwrap_or((tail, ""));
    let path = if path.is_empty() { "/" } else { path };
    let kept: Vec<&str> = query.split('&').filter(|param| !is_tracking(param)).collect();
    let mut normal = format!("{scheme}://{host}");
    if let Some(port) = port {
        normal.push_str(&format!(":{port}"));
    }
    normal.push_str(path);
    let query = kept.join("&");
    if !query.is_empty() {
        normal.push('?');
        normal.push_str(&query);
    }
    Some(WebUrl {
        host,
        port,
        path: path.to_string(),
        normal,
    })
}

fn is_tracking(param: &str) -> bool {
    let name = param.split('=').next().unwrap_or_default().to_ascii_lowercase();
    name.starts_with("utm_") || name == "fbclid" || name == "gclid"
}

/// The lowercase host and the port of an authority without a user name.
fn split_port(authority: &str) -> Option<(String, Option<u16>)> {
    let (host, port) = if authority.starts_with('[') {
        let (host, after) = authority.split_at(authority.find(']')? + 1);
        if after.is_empty() {
            (host, "")
        } else {
            (host, after.strip_prefix(':')?)
        }
    } else {
        authority.split_once(':').unwrap_or((authority, ""))
    };
    if !valid_host(host) || !port.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let port = if port.is_empty() {
        None
    } else {
        Some(port.parse().ok()?)
    };
    Some((host.to_lowercase(), port))
}

fn valid_host(host: &str) -> bool {
    match host.strip_prefix('[') {
        Some(inner) => inner
            .strip_suffix(']')
            .is_some_and(|ip| !ip.is_empty() && ip.chars().all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.')),
        None => {
            !host.is_empty()
                && host
                    .chars()
                    .all(|c| c.is_alphanumeric() || c == '-' || c == '.' || c == '_')
        }
    }
}

/// None when the decoded bytes are not UTF-8. A `%` that starts no escape
/// stays as it is.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let escaped = match bytes[i] {
            b'%' => hex_pair(&bytes[i + 1..]),
            _ => None,
        };
        match escaped {
            Some(byte) => {
                out.push(byte);
                i += 3;
            }
            None => {
                out.push(bytes[i]);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

fn hex_pair(bytes: &[u8]) -> Option<u8> {
    let high = char::from(*bytes.first()?).to_digit(16)?;
    let low = char::from(*bytes.get(1)?).to_digit(16)?;
    u8::try_from(high * 16 + low).ok()
}
