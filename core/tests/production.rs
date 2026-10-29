//! Read-only operations against the production ISDS, with the boxes of a
//! real archive that log in with name and password stored in `dsgui.conf`:
//!
//! `DATOVKA_DIR=~/.dsgui DATOVKA_LIVE=1 cargo test -p datovka-core --test production -- --ignored --nocapture`
//!
//! Nothing is sent, marked, deleted or changed, and nothing paid is called
//! (no re-signing). Logging in counts as delivery of waiting messages, as
//! with every download, so only boxes that download on their own are used.
//! Passwords are never printed.

use chrono::{Datelike, Duration, Utc};
use datovka_core::isds::{Client, Credentials, LoginMethod, SearchType};
use datovka_core::legacy::{conf, LegacyStore};
use datovka_core::model::Direction;

fn show<T>(op: &str, r: &datovka_core::Result<T>, what: impl FnOnce(&T) -> String) -> bool {
    match r {
        Ok(v) => {
            println!("  {op}: ok {}", what(v));
            true
        }
        Err(e) => {
            println!("  {op}: CHYBA {e}");
            false
        }
    }
}

#[tokio::test]
#[ignore]
async fn read_only_operations() {
    let (Ok(dir), Ok(_)) = (std::env::var("DATOVKA_DIR"), std::env::var("DATOVKA_LIVE")) else {
        return;
    };
    let store = LegacyStore::new(&dir);
    // dsgui.conf only: the system password store would ask the user.
    let accounts = conf::load(std::path::Path::new(&dir)).unwrap();
    let mut failed = 0;
    for acc in accounts {
        if acc.test_env || acc.pin_protected || !matches!(acc.login, LoginMethod::Password) {
            println!("{}: přeskočeno ({:?})", acc.name, acc.login);
            continue;
        }
        let Some(password) = acc.password.clone() else {
            println!("{}: přeskočeno (heslo není v dsgui.conf)", acc.name);
            continue;
        };
        println!("{}", acc.name);
        let c = Client::new(Credentials {
            username: acc.username.clone(),
            password,
            method: LoginMethod::Password,
            test_env: false,
        })
        .unwrap();
        let mut ok = |b: bool| failed += usize::from(!b);

        let owner = c.owner_info().await;
        ok(show("GetOwnerInfoFromLogin", &owner, |o| format!("{} {:?}", o.box_id, o.box_type)));
        let Ok(owner) = owner else { continue };
        let me = owner.box_id.clone();
        ok(show("GetOwnerInfoFromLogin2", &c.owner_info2().await, |v| {
            format!("{} polí", v.as_object().map_or(0, |m| m.len()))
        }));
        ok(show("GetUserInfoFromLogin2", &c.user_info2().await, |v| {
            format!("{} polí", v.as_object().map_or(0, |m| m.len()))
        }));
        ok(show("GetPasswordInfo", &c.password_expiry().await, |d| format!("{d:?}")));
        // Needs the privilege to manage users; ISDS refuses it otherwise.
        show("GetDataBoxUsers2", &c.box_users(&me).await, |v| {
            let n = v.pointer("/dbUsers/dbUserInfo").map_or(0, |u| u.as_array().map_or(1, Vec::len));
            format!("{n} uživatelů")
        });

        let found = c.search_boxes("Ministerstvo vnitra", SearchType::General, true, 0).await;
        ok(show("ISDSSearch3", &found, |p| {
            format!("{} celkem, {} na stránce, první {:?}", p.total, p.entries.len(), p.entries.first().map(|e| &e.name))
        }));
        let other = found
            .ok()
            .and_then(|p| p.entries.into_iter().next())
            .map(|e| e.box_id)
            .unwrap_or_else(|| me.clone());
        ok(show("ISDSSearch3 IČO", &c.search_boxes("00007064", SearchType::Ico, false, 0).await, |p| {
            format!("{} výsledků", p.entries.len())
        }));
        ok(show("CheckDataBox", &c.check_box(&other).await, |s| format!("stav {s}")));
        ok(show("PDZSendInfo", &c.pdz_send_info(&other, "Normal").await, |b| format!("{b}")));
        ok(show("DataBoxCreditInfo", &c.credit_info(&me).await, |v| {
            format!("kredit {:?}", v.get("currentCredit"))
        }));
        ok(show("DTInfo", &c.dt_info(&me).await, |v| {
            format!("{} polí", v.as_object().map_or(0, |m| m.len()))
        }));
        ok(show("PDZInfo", &c.pdz_info(&me).await, |v| {
            format!("{} polí", v.as_object().map_or(0, |m| m.len()))
        }));
        let week = (Utc::now() - Duration::days(7)).to_rfc3339();
        ok(show("GetMessageStateChanges", &c.state_changes(&week).await, |v| {
            format!("{} polí", v.as_object().map_or(0, |m| m.len()))
        }));

        let msgs = store.messages(&acc).unwrap_or_default();
        let newest = |d: Direction| {
            msgs.iter()
                .filter(|m| m.direction == d && m.has_zfo)
                .max_by_key(|m| m.delivery_time)
        };
        if let Some(m) = newest(Direction::Received) {
            ok(show("GetMessageAuthor2", &c.message_author(&m.dm_id.to_string()).await, |v| {
                format!("{} polí", v.as_object().map_or(0, |m| m.len()))
            }));
            if let Ok(Some(zfo)) = store.zfo(&acc, m.dm_id) {
                ok(show("AuthenticateMessage", &c.authenticate_any(&zfo).await, |(b, op)| {
                    format!("{b} ({op})")
                }));
            }
        }
        if let Some(m) = newest(Direction::Sent) {
            if let Ok(Some(zfo)) = store.zfo(&acc, m.dm_id) {
                ok(show("AuthenticateMessage odeslané", &c.authenticate_any(&zfo).await, |(b, op)| {
                    format!("{b} ({op})")
                }));
            }
        }

        // ISDS lists erased messages only three or more months back.
        let back = Utc::now() - Duration::days(130);
        let erased = c
            .erased_messages(back.year(), Some(back.month()), true, std::time::Duration::from_secs(90))
            .await;
        ok(show("GetListOfErasedMessages + PickUpAsyncResponse", &erased, |l| {
            format!("{}/{}: {} zpráv", back.month(), back.year(), l.len())
        }));
    }
    assert_eq!(failed, 0, "některé operace selhaly");
}
