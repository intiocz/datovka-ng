//! Filtered message list. The scan stays next to the database files; only the
//! requested page crosses the FFI boundary into the UI.

use std::collections::BTreeMap;

use chrono::{DateTime, Datelike, Local, NaiveDate, Utc};
use serde::Serialize;

use super::LegacyAccount;
use super::LegacyStore;
use crate::error::Result;
use crate::model::Direction;

#[derive(Debug, Clone)]
pub struct MessageFilter {
    /// Empty means every account that was passed in.
    pub usernames: Vec<String>,
    /// `inbox`, `sent`, `deadlines`, `all`, or `drafts`.
    pub folder: String,
    pub query: String,
    /// Exact data-box id of the other party. Matches messages received from
    /// them and messages sent to them.
    pub party_box_id: Option<String>,
    pub from: Option<NaiveDate>,
    pub to: Option<NaiveDate>,
    pub unread_only: bool,
    pub with_deadline: bool,
    pub tag: Option<String>,
    /// `0` returns every match (exports). Otherwise a page size.
    pub limit: usize,
    pub offset: usize,
}

impl MessageFilter {
    pub fn from_json(v: &serde_json::Value) -> Self {
        let strings = |k: &str| -> Vec<String> {
            v.get(k)
                .and_then(|x| x.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|s| s.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default()
        };
        let day = |k: &str| -> Option<NaiveDate> {
            v.get(k)
                .and_then(|x| x.as_str())
                .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
        };
        let text = |k: &str| {
            v.get(k)
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        Self {
            usernames: strings("usernames"),
            folder: text("folder").unwrap_or_else(|| "inbox".into()),
            query: v
                .get("query")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
            party_box_id: text("party_box_id"),
            from: day("from"),
            to: day("to"),
            unread_only: v.get("unread_only").and_then(|x| x.as_bool()).unwrap_or(false),
            with_deadline: v
                .get("with_deadline")
                .and_then(|x| x.as_bool())
                .unwrap_or(false),
            tag: text("tag"),
            limit: v.get("limit").and_then(|x| x.as_u64()).unwrap_or(200) as usize,
            offset: v.get("offset").and_then(|x| x.as_u64()).unwrap_or(0) as usize,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct ListedMessage {
    #[serde(flatten)]
    pub summary: super::MessageSummary,
    pub tags: Vec<String>,
    pub deadline: Option<String>,
    /// Note of the original app (`tag.db`).
    pub note: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ContactSummary {
    pub box_id: String,
    pub name: String,
    pub address: String,
    pub count: i64,
    pub last: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct MessagePage {
    pub messages: Vec<ListedMessage>,
    pub total: usize,
    pub unread: BTreeMap<String, i64>,
    pub deadline_count: i64,
    /// Messages with a deadline per account, so one box shows only its own.
    pub deadlines: BTreeMap<String, i64>,
    pub contacts: Vec<ContactSummary>,
    pub all_tags: Vec<String>,
    /// `YYYY-MM` → number of messages the filter keeps, ignoring its dates.
    pub months: BTreeMap<String, i64>,
}

/// Same folding as the app: Czech diacritics stripped, then lowercased.
pub fn fold(s: &str) -> String {
    const FROM: &str = "áčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ";
    const TO: &str = "acdeeinorstuuyzACDEEINORSTUUYZ";
    let from: Vec<char> = FROM.chars().collect();
    let to: Vec<char> = TO.chars().collect();
    let mapped: String = s
        .chars()
        .map(|c| {
            from.iter()
                .position(|f| *f == c)
                .map(|i| to[i])
                .unwrap_or(c)
        })
        .collect();
    mapped.to_lowercase()
}

struct Party {
    box_id: String,
    name: String,
    address: String,
}

fn party(m: &super::MessageSummary) -> Party {
    let sent = m.direction == Direction::Sent;
    Party {
        box_id: (if sent {
            m.recipient_box_id.clone()
        } else {
            m.sender_box_id.clone()
        })
        .unwrap_or_default(),
        name: (if sent { m.recipient.clone() } else { m.sender.clone() }).unwrap_or_default(),
        address: (if sent {
            m.recipient_address.clone()
        } else {
            m.sender_address.clone()
        })
        .unwrap_or_default(),
    }
}

fn when(m: &super::MessageSummary) -> Option<DateTime<Utc>> {
    m.delivery_time.or(m.acceptance_time)
}

impl LegacyStore {
    /// One pass over the stored envelopes. Counts and contacts cover every
    /// message of the accounts; `messages` is only the filtered page.
    pub fn query_messages(
        &self,
        accounts: &[LegacyAccount],
        filter: &MessageFilter,
    ) -> Result<MessagePage> {
        let tag_rows = self.message_tags()?;
        let mut tags: BTreeMap<(bool, i64), Vec<String>> = BTreeMap::new();
        for t in tag_rows {
            tags.entry((t.test_env, t.message_id))
                .or_default()
                .push(t.value);
        }
        let mut notes: BTreeMap<(bool, i64), String> = BTreeMap::new();
        for n in self.message_notes()? {
            notes.insert((n.test_env, n.message_id), n.value);
        }
        let mut deadlines: BTreeMap<(String, i64), String> = BTreeMap::new();
        for d in self.deadlines()? {
            deadlines.insert((d.user_name, d.message_id), d.value);
        }
        let words: Vec<String> = fold(&filter.query)
            .split_whitespace()
            .map(str::to_string)
            .collect();
        let all_tags = self.tags()?.into_iter().map(|t| t.name).collect();

        let mut unread: BTreeMap<String, i64> = BTreeMap::new();
        let mut deadline_count = 0_i64;
        let mut deadlines_by: BTreeMap<String, i64> = BTreeMap::new();
        let mut people: BTreeMap<String, ContactSummary> = BTreeMap::new();
        let mut matched: Vec<ListedMessage> = Vec::new();
        let mut months: BTreeMap<String, i64> = BTreeMap::new();

        for acc in accounts {
            for m in self.messages(acc)? {
                let key = (m.username.clone(), m.dm_id);
                let msg_tags = tags
                    .get(&(acc.test_env, m.dm_id))
                    .cloned()
                    .unwrap_or_default();
                let deadline = deadlines.get(&key).cloned();
                let received = m.direction == Direction::Received;
                if received && !m.read_locally {
                    *unread.entry(m.username.clone()).or_default() += 1;
                }
                if deadline.is_some() {
                    deadline_count += 1;
                    *deadlines_by.entry(m.username.clone()).or_default() += 1;
                }
                let p = party(&m);
                if !p.box_id.is_empty() {
                    let moment = when(&m).unwrap_or_else(Utc::now);
                    people
                        .entry(p.box_id.clone())
                        .and_modify(|c| {
                            let newer = moment > c.last;
                            if newer && !p.name.is_empty() {
                                c.name = p.name.clone();
                            }
                            if newer && !p.address.is_empty() {
                                c.address = p.address.clone();
                            }
                            c.count += 1;
                            if newer {
                                c.last = moment;
                            }
                        })
                        .or_insert(ContactSummary {
                            box_id: p.box_id.clone(),
                            name: p.name.clone(),
                            address: p.address.clone(),
                            count: 1,
                            last: moment,
                        });
                }
                if !keeps(&m, &msg_tags, deadline.as_deref(), filter, &words) {
                    continue;
                }
                // Months of everything the filter keeps apart from its dates,
                // so the year and month bar can offer the other periods too.
                if let Some(t) = when(&m) {
                    let t = t.with_timezone(&Local);
                    *months.entry(format!("{:04}-{:02}", t.year(), t.month())).or_default() += 1;
                }
                if !in_range(&m, filter) {
                    continue;
                }
                let note = notes.get(&(acc.test_env, m.dm_id)).cloned();
                matched.push(ListedMessage {
                    summary: m,
                    tags: msg_tags,
                    deadline,
                    note,
                });
            }
        }

        if filter.folder == "deadlines" {
            matched.sort_by(|a, b| a.deadline.cmp(&b.deadline));
        } else {
            matched.sort_by(|a, b| when(&b.summary).cmp(&when(&a.summary)));
        }
        let total = matched.len();
        let messages: Vec<_> = matched
            .into_iter()
            .skip(filter.offset)
            .take(if filter.limit == 0 {
                usize::MAX
            } else {
                filter.limit
            })
            .collect();
        let mut contacts: Vec<_> = people.into_values().collect();
        contacts.sort_by(|a, b| b.count.cmp(&a.count).then(b.last.cmp(&a.last)));
        Ok(MessagePage {
            messages,
            total,
            unread,
            deadline_count,
            deadlines: deadlines_by,
            months,
            contacts,
            all_tags,
        })
    }
}

/// Whether the message falls into the date range of the filter.
fn in_range(m: &super::MessageSummary, f: &MessageFilter) -> bool {
    match when(m).map(|t| t.with_timezone(&Local).date_naive()) {
        Some(day) => !(f.from.is_some_and(|from| day < from) || f.to.is_some_and(|to| day > to)),
        None => f.from.is_none() && f.to.is_none(),
    }
}

/// Everything of the filter except the date range, which [in_range] checks.
fn keeps(
    m: &super::MessageSummary,
    tags: &[String],
    deadline: Option<&str>,
    f: &MessageFilter,
    words: &[String],
) -> bool {
    if !f.usernames.is_empty() && !f.usernames.iter().any(|u| u == &m.username) {
        return false;
    }
    let received = m.direction == Direction::Received;
    match f.folder.as_str() {
        "inbox" if !received => return false,
        "sent" if received => return false,
        "deadlines" if deadline.is_none() => return false,
        "drafts" => return false,
        _ => {}
    }
    if f.unread_only && (!received || m.read_locally) {
        return false;
    }
    if f.with_deadline && deadline.is_none() {
        return false;
    }
    if let Some(tag) = &f.tag {
        if !tags.iter().any(|t| t == tag) {
            return false;
        }
    }
    if let Some(id) = &f.party_box_id {
        if &party(m).box_id != id {
            return false;
        }
    }
    if words.is_empty() {
        return true;
    }
    let p = party(m);
    let sent = m.direction == Direction::Sent;
    let our = if sent {
        m.sender_ref_number.as_deref()
    } else {
        m.recipient_ref_number.as_deref()
    };
    let their = if sent {
        m.recipient_ref_number.as_deref()
    } else {
        m.sender_ref_number.as_deref()
    };
    let hay = fold(&format!(
        "{} {} {} {} {} {} {} {}",
        m.annotation.as_deref().unwrap_or(""),
        p.name,
        p.address,
        p.box_id,
        m.dm_id,
        our.unwrap_or(""),
        their.unwrap_or(""),
        tags.join(" ")
    ));
    words.iter().all(|w| hay.contains(w))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn account() -> LegacyAccount {
        LegacyAccount {
            username: "abc".into(),
            ..Default::default()
        }
    }

    fn seed() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "datovka-query-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let c = Connection::open(dir.join("abc_2026___0.db")).unwrap();
        c.execute_batch(
            "CREATE TABLE messages (
                dmID INTEGER PRIMARY KEY,
                dmAnnotation TEXT, dmSender TEXT, dmSenderAddress TEXT, dbIDSender TEXT,
                dmRecipient TEXT, dmRecipientAddress TEXT, dbIDRecipient TEXT,
                dmSenderRefNumber TEXT, dmRecipientRefNumber TEXT,
                dmDeliveryTime TEXT, dmAcceptanceTime TEXT, dmMessageStatus INTEGER
            );
            CREATE TABLE supplementary_message_data (
                message_id INTEGER PRIMARY KEY, message_type INTEGER,
                read_locally INTEGER, attsNum INTEGER
            );
            CREATE TABLE raw_message_data (message_id INTEGER PRIMARY KEY, data TEXT);",
        )
        .unwrap();
        let rows = [
            (1, 1, "Zpráva o kontrole", "Úřad", "urad1", 0),
            (2, 1, "Faktura", "Dodavatel", "dodav", 1),
            (3, 2, "Odpověď", "Úřad", "urad1", 1),
        ];
        for (id, kind, subject, who, party, read) in rows {
            let (sender, recipient, sender_box, recipient_box) = if kind == 2 {
                ("My", who, "abcbox", party)
            } else {
                (who, "My", party, "abcbox")
            };
            c.execute(
                "INSERT INTO messages (dmID, dmAnnotation, dmSender, dmSenderAddress, dbIDSender,
                    dmRecipient, dmRecipientAddress, dbIDRecipient, dmDeliveryTime)
                 VALUES (?1, ?2, ?3, '', ?4, ?5, '', ?6, ?7)",
                rusqlite::params![
                    id,
                    subject,
                    sender,
                    sender_box,
                    recipient,
                    recipient_box,
                    format!("2026-05-0{id} 10:00:00.000+00:00")
                ],
            )
            .unwrap();
            c.execute(
                "INSERT INTO supplementary_message_data (message_id, message_type, read_locally, attsNum)
                 VALUES (?1, ?2, ?3, 0)",
                [id, kind, read],
            )
            .unwrap();
        }
        dir
    }

    #[test]
    fn page_is_filtered_and_counted() {
        let dir = seed();
        let store = LegacyStore::new(&dir);
        let page = store
            .query_messages(
                &[account()],
                &MessageFilter {
                    usernames: vec!["abc".into()],
                    folder: "inbox".into(),
                    query: "zprava".into(),
                    party_box_id: None,
                    from: None,
                    to: None,
                    unread_only: false,
                    with_deadline: false,
                    tag: None,
                    limit: 1,
                    offset: 0,
                },
            )
            .unwrap();
        assert_eq!(page.total, 1, "diacritics: zprava matches Zpráva");
        assert_eq!(page.messages.len(), 1);
        assert_eq!(page.messages[0].summary.dm_id, 1);
        assert_eq!(page.unread.get("abc").copied(), Some(1));
        assert_eq!(page.contacts.len(), 2);
        assert!(page.deadlines.is_empty());
        {
            let crate::legacy::lock::Acquire::Acquired(l) =
                crate::legacy::lock::acquire(&dir, "t").unwrap()
            else {
                panic!("zámek")
            };
            store.set_deadline(&l, "abc", 1, Some("2026-11-12")).unwrap();
            store.set_deadline(&l, "jineho", 9, Some("2026-11-12")).unwrap();
        }
        let page = store
            .query_messages(
                &[account()],
                &MessageFilter {
                    usernames: vec!["abc".into()],
                    folder: "deadlines".into(),
                    query: String::new(),
                    party_box_id: None,
                    from: None,
                    to: None,
                    unread_only: false,
                    with_deadline: false,
                    tag: None,
                    limit: 10,
                    offset: 0,
                },
            )
            .unwrap();
        assert_eq!(
            page.deadlines.get("abc").copied(),
            Some(1),
            "each box counts its own deadlines"
        );
        assert_eq!(page.deadlines.get("jineho"), None, "not a message of this archive");
        let with = store
            .query_messages(
                &[account()],
                &MessageFilter {
                    usernames: vec!["abc".into()],
                    folder: "all".into(),
                    query: String::new(),
                    party_box_id: Some("urad1".into()),
                    from: None,
                    to: None,
                    unread_only: false,
                    with_deadline: false,
                    tag: None,
                    limit: 10,
                    offset: 0,
                },
            )
            .unwrap();
        assert_eq!(with.total, 2, "received from and sent to the same box");
        assert_eq!(with.months.values().sum::<i64>(), 2);
        let none_then = store
            .query_messages(
                &[account()],
                &MessageFilter {
                    usernames: vec!["abc".into()],
                    folder: "all".into(),
                    query: String::new(),
                    party_box_id: Some("urad1".into()),
                    from: NaiveDate::from_ymd_opt(1990, 1, 1),
                    to: NaiveDate::from_ymd_opt(1990, 12, 31),
                    unread_only: false,
                    with_deadline: false,
                    tag: None,
                    limit: 10,
                    offset: 0,
                },
            )
            .unwrap();
        assert_eq!(none_then.total, 0);
        assert_eq!(
            none_then.months, with.months,
            "the months ignore the chosen period, so the bar can offer the others"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn fold_strips_czech_diacritics() {
        assert_eq!(fold("Příliš žluťoučký"), "prilis zlutoucky");
    }
}
