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

/// Like [`sync_account`] with an already logged-in client (e.g. a mobile key session).
pub async fn sync_with(
    client: &Client,
    store: &LegacyStore,
    lock: &WriteLock,
    account: &LegacyAccount,
) -> Result<SyncReport> {
    let mut report = SyncReport {
        username: account.username.clone(),
        ..Default::default()
    };
    for direction in [Direction::Received, Direction::Sent] {
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
            if store.contains(account, dm_id)? {
                continue;
            }
            let zfo = match direction {
                Direction::Received => client.download_received(&env.dm_id).await,
                Direction::Sent => client.download_sent(&env.dm_id).await,
            };
            // High-volume messages (VoDZ) are downloaded through their own service.
            let zfo = match zfo {
                Ok(z) => Ok(z),
                Err(first) => match direction {
                    Direction::Received => client.download_big_received(&env.dm_id).await,
                    Direction::Sent => client.download_big_sent(&env.dm_id).await,
                }
                .map_err(|_| first),
            };
            let zfo = match zfo {
                Ok(z) => z,
                Err(e) => {
                    report.errors.push(format!("{}: {e}", env.dm_id));
                    continue;
                }
            };
            let di = client.download_delivery_info(&env.dm_id).await.ok();
            match store.insert_message(lock, account, direction, &zfo, di.as_deref()) {
                Ok(true) => match direction {
                    Direction::Received => report.new_received += 1,
                    Direction::Sent => report.new_sent += 1,
                },
                Ok(false) => {}
                Err(e) => report.errors.push(format!("{}: {e}", env.dm_id)),
            }
        }
    }
    Ok(report)
}
