//! Downloading new messages from ISDS into the original databases.

use serde::Serialize;

use super::lock::WriteLock;
use super::{LegacyAccount, LegacyStore};
use crate::error::{Error, Result};
use crate::isds::{Client, Credentials, ListFilter, LoginMethod};
use crate::model::Direction;

#[derive(Debug, Clone, Default, Serialize)]
pub struct SyncReport {
    pub username: String,
    pub new_received: usize,
    pub new_sent: usize,
    pub errors: Vec<String>,
}

/// ISDS client for an account using the credentials stored in `dsgui.conf`.
/// Interactive methods (SMS, OTP, mobile key) are refused, never prompted.
pub fn client_for(account: &LegacyAccount) -> Result<Client> {
    if account.pin_protected {
        return Err(Error::Isds {
            code: "pin".into(),
            text: "heslo je chráněné PINem, zadejte PIN".into(),
        });
    }
    match account.login {
        LoginMethod::Password => {}
        other => {
            return Err(Error::Isds {
                code: "login".into(),
                text: format!(
                    "{}: způsob přihlášení {other:?} vyžaduje přihlášení v aplikaci",
                    account.name
                ),
            })
        }
    }
    let password = account.password.clone().ok_or_else(|| Error::Isds {
        code: "password".into(),
        text: "heslo není uložené".into(),
    })?;
    Client::new(Credentials {
        username: account.username.clone(),
        password,
        method: LoginMethod::Password,
        test_env: account.test_env,
    })
}

pub async fn sync_account(
    store: &LegacyStore,
    lock: &WriteLock,
    account: &LegacyAccount,
) -> Result<SyncReport> {
    sync_with(&client_for(account)?, store, lock, account).await
}

/// Downloads one message from ISDS again, with its delivery info, and
/// replaces the stored copy. The old copy is kept when the download fails,
/// e.g. because ISDS has already deleted the message.
pub async fn redownload(
    client: &Client,
    store: &LegacyStore,
    lock: &WriteLock,
    account: &LegacyAccount,
    dm_id: i64,
    direction: Direction,
) -> Result<()> {
    let id = dm_id.to_string();
    let zfo = match direction {
        Direction::Received => client.download_received(&id).await,
        Direction::Sent => client.download_sent(&id).await,
    };
    let (zfo, big) = match zfo {
        Ok(z) => (z, false),
        Err(first) => match direction {
            Direction::Received => client.download_big_received(&id).await,
            Direction::Sent => client.download_big_sent(&id).await,
        }
        .map(|z| (z, true))
        .map_err(|_| first)?,
    };
    let di = client.download_delivery_info(&id).await.ok();
    if store.contains(account, dm_id)? {
        store.delete_message(lock, account, dm_id)?;
    }
    store.insert_message_as(lock, account, direction, &zfo, di.as_deref(), big)?;
    Ok(())
}

/// ISDS 1229: the message has not reached the recipient's box yet.
fn not_delivered_yet(e: &Error) -> bool {
    matches!(e, Error::Isds { code, .. } if code == "1229")
}

/// Like [`sync_account`] with an already logged-in client (e.g. a mobile key session).
pub async fn sync_with(
    client: &Client,
    store: &LegacyStore,
    lock: &WriteLock,
    account: &LegacyAccount,
) -> Result<SyncReport> {
    sync_directions(client, store, lock, account, &[Direction::Received, Direction::Sent]).await
}

/// Downloads new sent messages only. Unlike the list of received messages
/// (`GetListOfReceivedMessages`), this never counts as logging in to the box,
/// so it delivers nothing that waits there (ISDS operating rules).
pub async fn sync_sent(
    client: &Client,
    store: &LegacyStore,
    lock: &WriteLock,
    account: &LegacyAccount,
) -> Result<SyncReport> {
    sync_directions(client, store, lock, account, &[Direction::Sent]).await
}

async fn sync_directions(
    client: &Client,
    store: &LegacyStore,
    lock: &WriteLock,
    account: &LegacyAccount,
    directions: &[Direction],
) -> Result<SyncReport> {
    let mut report = SyncReport {
        username: account.username.clone(),
        ..Default::default()
    };
    // Messages an older Datovka NG stored without the details the original
    // app needs; quick when there are none.
    let _ = store.complete_signature_details(lock, account);
    for &direction in directions {
        let _ = lock.refresh();
        let list = match direction {
            Direction::Received => client.received_messages(&ListFilter::default()).await?,
            Direction::Sent => client.sent_messages(&ListFilter::default()).await?,
        };
        for env in list {
            let _ = lock.refresh();
            let Ok(dm_id) = env.dm_id.parse::<i64>() else {
                continue;
            };
            // ISDS may mark a message as suspicious days after delivery.
            if let Some(flag) = env.spec_mess_flag {
                if store.contains(account, dm_id)? {
                    let _ = store.set_spec_mess_flag(lock, account, dm_id, flag);
                    continue;
                }
            }
            if store.contains(account, dm_id)? {
                continue;
            }
            let zfo = match direction {
                Direction::Received => client.download_received(&env.dm_id).await,
                Direction::Sent => client.download_sent(&env.dm_id).await,
            };
            // High-volume messages (VoDZ) are downloaded through their own service.
            let mut big = env.vodz == Some(true);
            let zfo = match zfo {
                Ok(z) => Ok(z),
                Err(first) => match direction {
                    Direction::Received => client.download_big_received(&env.dm_id).await,
                    Direction::Sent => client.download_big_sent(&env.dm_id).await,
                }
                .inspect(|_| big = true)
                .map_err(|_| first),
            };
            let zfo = match zfo {
                Ok(z) => z,
                // A sent message ISDS has not yet delivered cannot be
                // downloaded; the next sync takes it.
                Err(e) if not_delivered_yet(&e) => continue,
                Err(e) => {
                    report.errors.push(format!("{}: {e}", env.dm_id));
                    continue;
                }
            };
            let di = client.download_delivery_info(&env.dm_id).await.ok();
            match store.insert_message_as(lock, account, direction, &zfo, di.as_deref(), big) {
                Ok(true) => {
                    if let Some(flag) = env.spec_mess_flag {
                        let _ = store.set_spec_mess_flag(lock, account, dm_id, flag);
                    }
                    match direction {
                        Direction::Received => report.new_received += 1,
                        Direction::Sent => report.new_sent += 1,
                    }
                }
                Ok(false) => {}
                Err(e) => report.errors.push(format!("{}: {e}", env.dm_id)),
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_not_yet_delivered_is_no_error() {
        let wait = Error::Isds {
            code: "1229".into(),
            text: "Zpráva dosud nebyla dodána do schránky příjemce.".into(),
        };
        assert!(not_delivered_yet(&wait));
        let other = Error::Isds { code: "1219".into(), text: "x".into() };
        assert!(!not_delivered_yet(&other));
    }
}
