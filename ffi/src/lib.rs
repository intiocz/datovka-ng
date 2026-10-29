//! C ABI over the core for the Flutter app (`dart:ffi`).
//!
//! Every function takes UTF-8 C strings and returns a JSON C string
//! `{"ok": <value>}` or `{"error": "<message>"}` that the caller frees with
//! [`dk_free`]. Secrets (passwords, tokens) never cross this boundary.

// The exported functions take raw C pointers by design; validity is the caller's contract.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use datovka_core::isds::{ops, Client, LoginMethod, LoginStep, MobileKeyLogin};
use datovka_core::legacy::{lock, LegacyAccount, LegacyStore};
use serde_json::{json, Value};

fn arg(p: *const c_char) -> Result<String, String> {
    if p.is_null() {
        return Err("chybí argument".into());
    }
    // SAFETY: the caller passes a valid NUL-terminated string that outlives this call.
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(str::to_string)
        .map_err(|e| e.to_string())
}

fn respond(r: Result<Value, String>) -> *mut c_char {
    let v = match r {
        Ok(v) => json!({ "ok": v }),
        Err(e) => json!({ "error": e }),
    };
    CString::new(v.to_string())
        .unwrap_or_else(|_| CString::new(r#"{"error":"NUL v odpovědi"}"#).unwrap())
        .into_raw()
}

fn store(dir: *const c_char) -> Result<LegacyStore, String> {
    let dir = arg(dir)?;
    let dir = if dir.is_empty() {
        LegacyStore::default_dir().ok_or("neznámý domovský adresář")?
    } else {
        PathBuf::from(dir)
    };
    Ok(LegacyStore::new(dir))
}

fn e(err: impl std::fmt::Display) -> String {
    err.to_string()
}

/// Frees a string returned by any `dk_*` function.
#[no_mangle]
pub extern "C" fn dk_free(p: *mut c_char) {
    if !p.is_null() {
        // SAFETY: `p` was produced by `CString::into_raw` in `respond`.
        drop(unsafe { CString::from_raw(p) });
    }
}

/// Accounts with box details. `dir` empty means `~/.dsgui`.
#[no_mangle]
pub extern "C" fn dk_accounts(dir: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let mut out = Vec::new();
        for a in s.accounts().map_err(e)? {
            let info = s.box_info(&a).map_err(e)?;
            out.push(datovka_core::legacy::public_account(
                &a,
                &info,
                pin().lock().unwrap().is_some(),
            ));
        }
        Ok(json!({ "dir": s.dir(), "accounts": out }))
    })())
}

#[no_mangle]
pub extern "C" fn dk_messages(dir: *const c_char, username: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        Ok(serde_json::to_value(s.messages(&acc).map_err(e)?).map_err(e)?)
    })())
}

/// Filtered page of messages plus unread counts and contacts.
/// `spec` is JSON (`usernames`, `folder`, `query`, `from`, `to`, `limit`, …).
#[no_mangle]
pub extern "C" fn dk_message_query(dir: *const c_char, spec: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let spec: Value = serde_json::from_str(&arg(spec)?).map_err(e)?;
        let accounts = s.accounts().map_err(e)?;
        let filter = datovka_core::legacy::query::MessageFilter::from_json(&spec);
        let page = s.query_messages(&accounts, &filter).map_err(e)?;
        Ok(serde_json::to_value(page).map_err(e)?)
    })())
}

/// `op` is `status`, `acquire`, `take`, `refresh`, or `release`.
/// A stale lock is reported, not taken, until `take`.
#[no_mangle]
pub extern "C" fn dk_lock(
    dir: *const c_char,
    op: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let op = arg(op)?;
        let device = arg(device)?;
        let d = s.dir().to_path_buf();
        let held = |i: lock::LockInfo| {
            json!({
                "ok": false,
                "held": true,
                "device": i.device,
                "stale": i.is_stale(chrono::Utc::now()),
                "heartbeat": i.heartbeat,
            })
        };
        match op.as_str() {
            "status" => Ok(match lock::peek(&d) {
                Some(i) => json!({
                    "held": true,
                    "device": i.device,
                    "ours": i.device == device,
                    "stale": i.is_stale(chrono::Utc::now()),
                    "heartbeat": i.heartbeat,
                }),
                None => json!({ "held": false }),
            }),
            "acquire" | "refresh" => match lock::acquire(&d, &device).map_err(e)? {
                lock::Acquire::Acquired(_) => Ok(json!({ "ok": true, "held": true, "ours": true })),
                lock::Acquire::HeldBy(i) => Ok(held(i)),
            },
            "take" => {
                lock::take(&d, &device).map_err(e)?;
                Ok(json!({ "ok": true, "held": true, "ours": true }))
            }
            "release" => {
                if let lock::Acquire::Acquired(l) = lock::acquire(&d, &device).map_err(e)? {
                    l.release().map_err(e)?;
                }
                Ok(json!({ "ok": true, "held": false }))
            }
            _ => Err("neznámá operace zámku".into()),
        }
    })())
}

#[no_mangle]
pub extern "C" fn dk_attachments(
    dir: *const c_char,
    username: *const c_char,
    dm_id: i64,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        Ok(serde_json::to_value(s.attachments(&acc, dm_id).map_err(e)?).map_err(e)?)
    })())
}

/// Writes an attachment to `out_path`.
#[no_mangle]
pub extern "C" fn dk_save_attachment(
    dir: *const c_char,
    username: *const c_char,
    dm_id: i64,
    id: i64,
    out_path: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let data = s.attachment_content(&acc, dm_id, id).map_err(e)?;
        let out = arg(out_path)?;
        std::fs::write(&out, data).map_err(e)?;
        Ok(json!(out))
    })())
}

/// Writes the signed message (ZFO) to `out_path`.
#[no_mangle]
pub extern "C" fn dk_save_zfo(
    dir: *const c_char,
    username: *const c_char,
    dm_id: i64,
    out_path: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let data = s
            .zfo(&acc, dm_id)
            .map_err(e)?
            .ok_or("zpráva nemá uložené ZFO")?;
        let out = arg(out_path)?;
        std::fs::write(&out, data).map_err(e)?;
        Ok(json!(out))
    })())
}

/// Sets the local read flag. Fails without writing when another device holds
/// the write lock.
#[no_mangle]
pub extern "C" fn dk_set_read(
    dir: *const c_char,
    username: *const c_char,
    dm_id: i64,
    read: bool,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(l) => {
                s.set_read_locally(&l, &acc, dm_id, read).map_err(e)?;
                Ok(json!(true))
            }
            lock::Acquire::HeldBy(i) => Err(format!(
                "data právě upravuje zařízení {}, změna se neuložila",
                i.device
            )),
        }
    })())
}

/// One runtime for the whole process: HTTP connection pools and cookie
/// sessions outlive single calls.
fn block_on<F: std::future::Future>(f: F) -> Result<F::Output, String> {
    static RT: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();
    let rt = RT
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .map_err(e)
        })
        .as_ref()
        .map_err(Clone::clone)?;
    Ok(rt.block_on(f))
}

/// Logged-in interactive sessions (OTP, SMS, mobile key) per username. They
/// live as long as the process; nothing ever re-logs in on its own.
fn sessions() -> &'static Mutex<HashMap<String, Client>> {
    static S: OnceLock<Mutex<HashMap<String, Client>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

fn pending_mep() -> &'static Mutex<HashMap<String, MobileKeyLogin>> {
    static P: OnceLock<Mutex<HashMap<String, MobileKeyLogin>>> = OnceLock::new();
    P.get_or_init(Default::default)
}

/// Prefix of errors meaning "log in again"; the app shows a quiet banner.
const SESSION_EXPIRED: &str = "session_expired";

/// PIN entered by the user for this run of the app (never stored).
fn pin() -> &'static Mutex<Option<String>> {
    static P: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    P.get_or_init(Default::default)
}

/// The account with its password decrypted when it is PIN-protected.
fn unlocked(acc: &LegacyAccount) -> Result<LegacyAccount, String> {
    if !acc.pin_protected {
        return Ok(acc.clone());
    }
    let p = pin()
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| format!("{SESSION_EXPIRED}: hesla jsou chráněná PINem, zadejte PIN"))?;
    let mut a = acc.clone();
    a.password = acc.password_with_pin(&p).map_err(e)?;
    a.pin_protected = false;
    Ok(a)
}

/// Checks and remembers the PIN for decrypting stored passwords.
#[no_mangle]
pub extern "C" fn dk_set_pin(dir: *const c_char, value: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let text = std::fs::read_to_string(s.dir().join("dsgui.conf")).map_err(e)?;
        let value = arg(value)?;
        let ok = datovka_core::legacy::pin::verify_pin(&text, &value).map_err(e)?;
        if ok {
            *pin().lock().unwrap() = Some(value);
        }
        Ok(json!(ok))
    })())
}

/// Client for an account: its interactive session, or stored password.
fn client(acc: &LegacyAccount) -> Result<Client, String> {
    if let Some(c) = sessions().lock().unwrap().get(&acc.username) {
        return Ok(c.clone());
    }
    let acc = &unlocked(acc)?;
    if acc.login != LoginMethod::Password {
        return Err(format!(
            "{SESSION_EXPIRED}: {} čeká na přihlášení",
            acc.name
        ));
    }
    datovka_core::legacy::sync::client_for(acc).map_err(e)
}

/// Maps errors of a call; an expired session is forgotten so the UI asks again.
fn session_err(acc: &LegacyAccount, err: datovka_core::Error) -> String {
    if matches!(err, datovka_core::Error::Unauthorized)
        && sessions().lock().unwrap().remove(&acc.username).is_some()
    {
        return format!(
            "{SESSION_EXPIRED}: přihlášení ke schránce {} vypršelo",
            acc.name
        );
    }
    e(err)
}

/// Downloads new messages of one account into the shared databases.
/// Blocking; call it off the UI thread.
#[no_mangle]
pub extern "C" fn dk_sync(
    dir: *const c_char,
    username: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    sync(dir, username, device, false)
}

/// Downloads new sent messages only; never delivers waiting messages.
#[no_mangle]
pub extern "C" fn dk_sync_sent(
    dir: *const c_char,
    username: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    sync(dir, username, device, true)
}

fn sync(
    dir: *const c_char,
    username: *const c_char,
    device: *const c_char,
    sent_only: bool,
) -> *mut c_char {
    use datovka_core::legacy::sync::{sync_sent, sync_with};
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        // Another computer or the phone may be writing. Wait, then download.
        // Reading never takes the lock, so the archive stays open everywhere.
        match lock::acquire_wait(s.dir(), &arg(device)?, std::time::Duration::from_secs(180))
            .map_err(e)?
        {
            lock::Acquire::Acquired(l) => {
                let c = client(&acc)?;
                let report = if sent_only {
                    block_on(sync_sent(&c, &s, &l, &acc))?
                } else {
                    block_on(sync_with(&c, &s, &l, &acc))?
                }
                .map_err(|err| session_err(&acc, err))?;
                Ok(serde_json::to_value(report).map_err(e)?)
            }
            lock::Acquire::HeldBy(i) => Err(format!(
                "data právě zapisuje zařízení {}. Čtení funguje, stahování zkuste znovu.",
                i.device
            )),
        }
    })())
}

/// Searches the ISDS data box directory, logged in as `username`.
/// `kind` is `general`, `address`, `ico` or `box_id`.
#[no_mangle]
pub extern "C" fn dk_search(
    dir: *const c_char,
    username: *const c_char,
    text: *const c_char,
    kind: *const c_char,
    authorities_only: bool,
    page: i64,
) -> *mut c_char {
    use datovka_core::isds::SearchType;
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let client = client(&acc)?;
        let kind = match arg(kind)?.as_str() {
            "address" => SearchType::Address,
            "ico" => SearchType::Ico,
            "box_id" => SearchType::BoxId,
            "id_ovm" => SearchType::IdOvm,
            _ => SearchType::General,
        };
        let text = arg(text)?;
        let page =
            block_on(client.search_boxes(&text, kind, authorities_only, page.max(0) as u32))?
                .map_err(e)?;
        Ok(serde_json::to_value(page).map_err(e)?)
    })())
}

#[derive(serde::Deserialize)]
struct SendRequest {
    #[serde(flatten)]
    message: datovka_core::isds::OutgoingMessage,
    /// Paths of files to attach; the first one is the main document.
    files: Vec<String>,
    /// Several recipients instead of `recipient_box_id`.
    #[serde(default)]
    recipients: Vec<String>,
}

/// Sends one message to several recipients with `CreateMultipleMessage`.
/// Recipients that ISDS did not accept in it (e.g. those reachable only by
/// a commercial message, which a multiple message cannot be) are sent one by
/// one, as before. Nothing was created for them, so nothing goes twice.
fn send_to_many(
    acc: &LegacyAccount,
    c: &Client,
    msg: &datovka_core::isds::OutgoingMessage,
    recipients: &[String],
) -> Result<Value, String> {
    use datovka_core::isds::MULTIPLE_MAX;
    let mut out = Vec::new();
    for chunk in recipients.chunks(MULTIPLE_MAX) {
        // The new message ID per recipient, `None` to send it on its own.
        let ids: Vec<Option<String>> = match block_on(c.create_multiple_message(msg, chunk))? {
            Ok(list) => list.into_iter().map(Result::ok).collect(),
            // ISDS refused the whole call before creating any message.
            Err(datovka_core::Error::Isds { code, .. })
                if code.bytes().all(|b| b.is_ascii_digit()) =>
            {
                vec![None; chunk.len()]
            }
            Err(err) if out.is_empty() => return Err(session_err(acc, err)),
            Err(err) => {
                let text = session_err(acc, err);
                out.extend(chunk.iter().map(|r| json!({ "box_id": r, "error": text })));
                continue;
            }
        };
        for (r, id) in chunk.iter().zip(ids) {
            let res = match id {
                Some(id) => Ok(id),
                None => {
                    let mut one = msg.clone();
                    one.recipient_box_id = r.clone();
                    block_on(c.create_message(&one))?.map_err(|err| session_err(acc, err))
                }
            };
            out.push(match res {
                Ok(id) => json!({ "box_id": r, "dm_id": id }),
                Err(text) => json!({ "box_id": r, "error": text }),
            });
        }
    }
    Ok(json!(out))
}

/// Sends a message from `username`. `request` is JSON: envelope fields of
/// `OutgoingMessage` plus `files` (paths). Returns the new message ID; with
/// `recipients` (more than one) a list of `{box_id, dm_id}` or
/// `{box_id, error}` instead.
#[no_mangle]
pub extern "C" fn dk_send(
    dir: *const c_char,
    username: *const c_char,
    request: *const c_char,
) -> *mut c_char {
    use datovka_core::isds::{mime_for, OutgoingFile};
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let req: SendRequest = serde_json::from_str(&arg(request)?).map_err(e)?;
        let mut msg = req.message;
        for path in &req.files {
            let p = std::path::Path::new(path);
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "priloha".into());
            msg.files.push(OutgoingFile {
                mime_type: mime_for(&name).to_string(),
                content: std::fs::read(p).map_err(|err| format!("{name}: {err}"))?,
                name,
            });
        }
        let c = client(&acc)?;
        // Over 20 MB a message must go as a high-volume message (VoDZ),
        // which ISDS cannot send to several recipients at once.
        let total: usize = msg.files.iter().map(|f| f.content.len()).sum();
        let big = total > 20 * 1024 * 1024;
        if req.recipients.len() > 1 && !big {
            return send_to_many(&acc, &c, &msg, &req.recipients);
        }
        if req.recipients.len() > 1 {
            let mut out = Vec::new();
            for r in &req.recipients {
                msg.recipient_box_id = r.clone();
                out.push(match block_on(c.send_big(&msg))? {
                    Ok(id) => json!({ "box_id": r, "dm_id": id }),
                    Err(err) => json!({ "box_id": r, "error": session_err(&acc, err) }),
                });
            }
            return Ok(json!(out));
        }
        if let [one] = req.recipients.as_slice() {
            msg.recipient_box_id = one.clone();
        }
        let dm_id = if big {
            block_on(c.send_big(&msg))?
        } else {
            block_on(c.create_message(&msg))?
        }
        .map_err(|err| session_err(&acc, err))?;
        Ok(json!(dm_id))
    })())
}

fn step(s: LoginStep) -> Value {
    json!({ "step": s })
}

/// Name and password login. ISDS checks the password, the session stays for
/// this run and a typed password goes into the system password store, so the
/// box logs in by itself next time. An empty password uses the stored one.
/// Returns whether the password was stored.
#[no_mangle]
pub extern "C" fn dk_login_password(
    dir: *const c_char,
    username: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = unlocked(&s.account(&arg(username)?).map_err(e)?)?;
        let typed = arg(password)?;
        let password = if typed.is_empty() {
            acc.password
                .clone()
                .ok_or("heslo není uložené, zadejte ho")?
        } else {
            typed.clone()
        };
        let c = Client::new(datovka_core::isds::Credentials {
            username: acc.username.clone(),
            password,
            method: LoginMethod::Password,
            test_env: acc.test_env,
        })
        .map_err(e)?;
        block_on(c.owner_info())?.map_err(e)?;
        sessions().lock().unwrap().insert(acc.username.clone(), c);
        let stored = !typed.is_empty()
            && !acc.pin_protected
            && datovka_core::legacy::secrets::set_password(&acc.username, acc.test_env, &typed)
                .is_ok();
        Ok(json!({ "stored": stored }))
    })())
}

/// Password + code login. `code` empty with `sms` asks ISDS to send an SMS.
/// The password comes from `dsgui.conf` when `password` is empty.
#[no_mangle]
pub extern "C" fn dk_login_otp(
    dir: *const c_char,
    username: *const c_char,
    password: *const c_char,
    code: *const c_char,
    sms: bool,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let typed = arg(password)?;
        let password = if typed.is_empty() {
            acc.password
                .clone()
                .ok_or("heslo není uložené, zadejte ho")?
        } else {
            typed
        };
        let code = arg(code)?;
        let code = (!code.trim().is_empty()).then(|| code.trim().to_string());
        let (st, c) = block_on(Client::login_otp(
            &acc.username,
            &password,
            code.as_deref(),
            sms,
            acc.test_env,
        ))?
        .map_err(e)?;
        if let Some(c) = c {
            sessions().lock().unwrap().insert(acc.username.clone(), c);
        }
        Ok(step(st))
    })())
}

/// Starts a mobile key login with the communication code from `dsgui.conf`;
/// ISDS sends a push to the phone. Poll with [`dk_login_mep_poll`].
#[no_mangle]
pub extern "C" fn dk_login_mep_start(dir: *const c_char, username: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let code = acc
            .mep_token
            .clone()
            .ok_or("schránka nemá uložený komunikační kód mobilního klíče")?;
        let login =
            block_on(Client::login_mobile_key(&acc.username, &code, acc.test_env))?.map_err(e)?;
        pending_mep().lock().unwrap().insert(acc.username, login);
        Ok(step(LoginStep::Waiting))
    })())
}

/// One poll of a pending mobile key login.
#[no_mangle]
pub extern "C" fn dk_login_mep_poll(username: *const c_char) -> *mut c_char {
    respond((|| {
        let username = arg(username)?;
        let mut login = pending_mep()
            .lock()
            .unwrap()
            .remove(&username)
            .ok_or("přihlášení mobilním klíčem neběží")?;
        match block_on(login.poll())?.map_err(e)? {
            LoginStep::Done => {
                sessions()
                    .lock()
                    .unwrap()
                    .insert(username, login.into_client());
                Ok(step(LoginStep::Done))
            }
            st => {
                pending_mep().lock().unwrap().insert(username, login);
                Ok(step(st))
            }
        }
    })())
}

/// Cancels a pending mobile key login and forgets any session of the account.
#[no_mangle]
pub extern "C" fn dk_logout(username: *const c_char) -> *mut c_char {
    respond((|| {
        let username = arg(username)?;
        pending_mep().lock().unwrap().remove(&username);
        sessions().lock().unwrap().remove(&username);
        Ok(json!(true))
    })())
}

/// Usernames with a live interactive session.
#[no_mangle]
pub extern "C" fn dk_sessions() -> *mut c_char {
    respond(Ok(json!(sessions()
        .lock()
        .unwrap()
        .keys()
        .collect::<Vec<_>>())))
}

/// Further ISDS operations, by name, with JSON arguments. Used for message
/// verification, author, erasing, box information, credit, data vault, users
/// and password change. Returns the operation's result as JSON.
#[no_mangle]
pub extern "C" fn dk_op(
    dir: *const c_char,
    username: *const c_char,
    op: *const c_char,
    args: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let args: Value = serde_json::from_str(&arg(args)?).map_err(e)?;
        let str_arg = |k: &str| -> Result<String, String> {
            args.get(k)
                .and_then(|v| match v {
                    Value::String(s) => Some(s.clone()),
                    Value::Number(n) => Some(n.to_string()),
                    _ => None,
                })
                .ok_or_else(|| format!("chybí argument {k}"))
        };
        let dm = || -> Result<i64, String> { str_arg("dm_id")?.parse().map_err(e) };
        let box_id = || -> Result<String, String> {
            match str_arg("box_id") {
                Ok(b) => Ok(b),
                Err(_) => s
                    .box_info(&acc)
                    .map_err(e)?
                    .box_id
                    .ok_or_else(|| "neznámé ID schránky".to_string()),
            }
        };
        let op = arg(op)?;
        // Local-only operations first; they need no login.
        if op == "save_delivery_zfo" {
            let data = s
                .delivery_zfo(&acc, dm()?)
                .map_err(e)?
                .ok_or("doručenka není uložená")?;
            let out = str_arg("path")?;
            std::fs::write(&out, data).map_err(e)?;
            return Ok(json!(out));
        }
        // Tags and deadlines: shared data, written under the device lock.
        let device = str_arg("device").unwrap_or_else(|_| "datovka".into());
        let with_lock =
            |f: &dyn Fn(&lock::WriteLock) -> datovka_core::Result<()>| match lock::acquire(
                s.dir(),
                &device,
            )
            .map_err(e)?
            {
                lock::Acquire::Acquired(l) => f(&l).map_err(e),
                lock::Acquire::HeldBy(i) => Err(format!(
                    "data právě upravuje zařízení {}, změna se neuložila",
                    i.device
                )),
            };
        match op.as_str() {
            "marks" => {
                return Ok(json!({
                    "tags": s.message_tags().map_err(e)?,
                    "notes": s.message_notes().map_err(e)?,
                    "deadlines": s.deadlines().map_err(e)?,
                    "all_tags": s.tags().map_err(e)?,
                }))
            }
            "set_tag" => {
                let on = args.get("on").and_then(Value::as_bool).unwrap_or(true);
                let name = str_arg("tag")?;
                let id = dm()?;
                with_lock(&|l| s.set_tag(l, &acc.username, acc.test_env, id, &name, on))?;
                return Ok(json!(true));
            }
            "set_note" => {
                let text = str_arg("note").unwrap_or_default();
                let id = dm()?;
                with_lock(&|l| s.set_note(l, acc.test_env, id, &text))?;
                return Ok(json!(true));
            }
            "set_deadline" => {
                let d = args
                    .get("deadline")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                let id = dm()?;
                with_lock(&|l| s.set_deadline(l, &acc.username, id, d.as_deref()))?;
                return Ok(json!(true));
            }
            "stamps" => {
                let days = args.get("days").and_then(Value::as_i64).unwrap_or(365);
                let until = chrono::Utc::now() + chrono::Duration::days(days);
                // Remember the answers when the folder is free; read anyway.
                let list = match lock::acquire(s.dir(), &device).map_err(e)? {
                    lock::Acquire::Acquired(l) => s.expiring_stamps(Some(&l), &acc, until),
                    lock::Acquire::HeldBy(_) => s.expiring_stamps(None, &acc, until),
                }
                .map_err(e)?;
                return Ok(serde_json::to_value(list).map_err(e)?);
            }
            "process_state" => {
                let state = args.get("state").and_then(Value::as_i64).ok_or("chybí stav")?;
                let id = dm()?;
                with_lock(&|l| s.set_process_state(l, &acc, id, state))?;
                return Ok(json!(true));
            }
            "delete_local" => {
                let id = dm()?;
                with_lock(&|l| s.delete_message(l, &acc, id))?;
                return Ok(json!(true));
            }
            "drafts" => return Ok(serde_json::to_value(s.drafts().map_err(e)?).map_err(e)?),
            "save_draft" => {
                let id = args.get("id").and_then(Value::as_i64);
                let content = str_arg("content")?;
                let out = std::cell::Cell::new(0);
                with_lock(&|l| {
                    out.set(s.save_draft(l, id, &acc.username, &content)?);
                    Ok(())
                })?;
                return Ok(json!(out.get()));
            }
            "delete_draft" => {
                let id = args.get("id").and_then(Value::as_i64).ok_or("chybí id")?;
                with_lock(&|l| s.delete_draft(l, id))?;
                return Ok(json!(true));
            }
            "import_zfo" => {
                let data = std::fs::read(str_arg("path")?).map_err(e)?;
                let received = args
                    .get("received")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                let dir = if received {
                    datovka_core::model::Direction::Received
                } else {
                    datovka_core::model::Direction::Sent
                };
                let added = std::cell::Cell::new(false);
                with_lock(&|l| {
                    added.set(s.insert_message(l, &acc, dir, &data, None)?);
                    Ok(())
                })?;
                return Ok(json!(added.get()));
            }
            _ => {}
        }
        if op == "verify_local" {
            let data = s
                .zfo(&acc, dm()?)
                .map_err(e)?
                .ok_or("zpráva nemá uložený originál")?;
            return serde_json::to_value(datovka_core::verify::verify_zfo(&data).map_err(e)?)
                .map_err(e);
        }
        if op == "verify_local_file" {
            let data = std::fs::read(str_arg("path")?).map_err(e)?;
            return serde_json::to_value(datovka_core::verify::verify_zfo(&data).map_err(e)?)
                .map_err(e);
        }
        if op == "delivery_events" {
            let data = s.delivery_zfo(&acc, dm()?).map_err(e)?;
            let events = match data {
                Some(d) => datovka_core::zfo::delivery_events(&d).map_err(e)?,
                None => Vec::new(),
            };
            return Ok(json!(events
                .into_iter()
                .map(|(t, d)| json!({ "time": t, "description": d }))
                .collect::<Vec<_>>()));
        }
        // Boxes logging in with password and code change the password at a
        // service of its own, authenticated by the old password and a code
        // (not by the session, so its errors never end the session).
        let otp = match acc.login {
            LoginMethod::PasswordTotp => Some(ops::Otp::Sms),
            LoginMethod::PasswordHotp => Some(ops::Otp::App),
            _ => None,
        };
        match (op.as_str(), otp) {
            ("send_sms_code", Some(ops::Otp::Sms)) => {
                block_on(ops::send_sms_code(&acc.username, &str_arg("old")?, acc.test_env))?
                    .map_err(e)?;
                return Ok(json!(true));
            }
            ("send_sms_code", _) => return Err("schránka se nepřihlašuje SMS kódem".into()),
            ("change_password", Some(otp)) => {
                let new = str_arg("new")?;
                let code = str_arg("code").unwrap_or_default();
                if code.trim().is_empty() {
                    return Err(if otp == ops::Otp::Sms {
                        "zadejte kód z SMS".into()
                    } else {
                        "zadejte bezpečnostní kód".into()
                    });
                }
                block_on(ops::change_password_otp(
                    &acc.username,
                    &str_arg("old")?,
                    &new,
                    &code,
                    otp,
                    acc.test_env,
                ))?
                .map_err(e)?;
                store_new_password(&s, &acc, &new)?;
                return Ok(json!(true));
            }
            _ => {}
        }
        let c = client(&acc)?;
        let fail = |err| session_err(&acc, err);
        let zfo = |id: i64| -> Result<Vec<u8>, String> {
            s.zfo(&acc, id)
                .map_err(e)?
                .ok_or("zpráva nemá uložené ZFO".into())
        };
        let v = match op.as_str() {
            "verify" => {
                // ISDS checks the whole stored ZFO (AuthenticateMessage); the
                // deprecated VerifyMessage compared only the hash.
                let data = zfo(dm()?)?;
                let (ok, method) = block_on(c.authenticate_any(&data))?.map_err(fail)?;
                let (local, algorithm) = match ops::zfo_hash(&data) {
                    Ok((h, a)) => (Some(h), a),
                    Err(_) => (None, None),
                };
                json!({
                    "match": ok,
                    "method": method,
                    "algorithm": algorithm,
                    "local_hash": local,
                })
            }
            "authenticate" => {
                let id = dm()?;
                json!(block_on(c.authenticate_any(&zfo(id)?))?.map_err(fail)?.0)
            }
            "authenticate_file" => {
                let data = std::fs::read(str_arg("path")?).map_err(e)?;
                json!(block_on(c.authenticate_any(&data))?.map_err(fail)?.0)
            }
            "check_box" => {
                let state = block_on(c.check_box(&str_arg("recipient")?))?.map_err(fail)?;
                json!({
                    "state": state,
                    "active": state == 1,
                    "text": ops::box_state_text(state),
                })
            }
            "pdz_send_info" => {
                let kind = str_arg("type").unwrap_or_else(|_| "Normal".into());
                json!(block_on(c.pdz_send_info(&str_arg("recipient")?, &kind))?.map_err(fail)?)
            }
            "author" => block_on(c.message_author(&dm()?.to_string()))?.map_err(fail)?,
            "resign" => {
                // Current (CAdES) documents get an archive stamp; ISDS answers
                // 2214 for old ones, which still need Re-signISDSDocument.
                let id = dm()?;
                let data = zfo(id)?;
                let (doc, valid_to) = match block_on(c.archive_document(&data))? {
                    Ok(x) => x,
                    Err(datovka_core::Error::Isds { code, .. }) if code == "2214" => {
                        block_on(c.resign_document(&data))?.map_err(fail)?
                    }
                    Err(datovka_core::Error::Isds { code, .. }) if code == "2206" => {
                        return Err("Časové razítko je ještě dlouho platné. Přerazítkovat jde \
                                    až v posledním roce a půl jeho platnosti."
                            .into())
                    }
                    Err(err) => return Err(fail(err)),
                };
                with_lock(&|l| {
                    s.replace_zfo(l, &acc, id, &doc)?;
                    s.forget_stamp(l, &acc.username, id)
                })?;
                json!({ "valid_to": valid_to })
            }
            "mark_read" => {
                block_on(c.mark_as_read(&dm()?.to_string()))?.map_err(fail)?;
                json!(true)
            }
            "erase" => {
                let incoming = args
                    .get("incoming")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                block_on(c.erase_message(&dm()?.to_string(), incoming))?.map_err(fail)?;
                json!(true)
            }
            "redownload" => {
                let incoming = args
                    .get("incoming")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                let direction = if incoming {
                    datovka_core::model::Direction::Received
                } else {
                    datovka_core::model::Direction::Sent
                };
                let id = dm()?;
                let done = std::cell::RefCell::new(None);
                with_lock(&|l| {
                    *done.borrow_mut() = Some(block_on(datovka_core::legacy::sync::redownload(
                        &c, &s, l, &acc, id, direction,
                    )));
                    Ok(())
                })?;
                match done.into_inner() {
                    Some(Ok(Ok(()))) => json!(true),
                    Some(Ok(Err(err))) => return Err(fail(err)),
                    Some(Err(err)) => return Err(err),
                    None => return Err("zpráva se nestáhla".into()),
                }
            }
            "owner_info" => block_on(c.owner_info2())?.map_err(fail)?,
            "user_info" => block_on(c.user_info2())?.map_err(fail)?,
            "password_expiry" => {
                json!(block_on(c.password_expiry())?
                    .map_err(fail)?
                    .map(|t| t.to_rfc3339()))
            }
            "change_password" => {
                let new = str_arg("new")?;
                block_on(c.change_password(&str_arg("old")?, &new))?.map_err(fail)?;
                store_new_password(&s, &acc, &new)?;
                json!(true)
            }
            "credit" => block_on(c.credit_info(&box_id()?))?.map_err(fail)?,
            "dt_info" => block_on(c.dt_info(&box_id()?))?.map_err(fail)?,
            "pdz_info" => block_on(c.pdz_info(&box_id()?))?.map_err(fail)?,
            "users" => block_on(c.box_users(&box_id()?))?.map_err(fail)?,
            "user_add" => {
                let user = args.get("user").cloned().ok_or("chybí údaje uživatele")?;
                block_on(c.add_user(&box_id()?, &user))?.map_err(fail)?
            }
            "user_update" => {
                let user = args.get("user").cloned().ok_or("chybí údaje uživatele")?;
                block_on(c.update_user(&box_id()?, &str_arg("isds_id")?, &user))?.map_err(fail)?;
                json!(true)
            }
            "user_delete" => {
                block_on(c.delete_user(&box_id()?, &str_arg("isds_id")?))?.map_err(fail)?;
                json!(true)
            }
            "erased" => {
                let year = str_arg("year")?.parse::<i32>().map_err(e)?;
                let month = args.get("month").and_then(Value::as_u64).map(|m| m as u32);
                let received = args.get("received").and_then(Value::as_bool).unwrap_or(true);
                let list = block_on(c.erased_messages(
                    year,
                    month,
                    received,
                    std::time::Duration::from_secs(60),
                ))?
                .map_err(fail)?;
                serde_json::to_value(list).map_err(e)?
            }
            other => return Err(format!("neznámá operace {other}")),
        };
        Ok(v)
    })())
}

/// Keeps the stored password in sync after a change so downloading keeps
/// working, where it is: dsgui.conf of the original app, or the system store.
fn store_new_password(s: &LegacyStore, acc: &LegacyAccount, new: &str) -> Result<(), String> {
    if acc.password.is_none() {
        return Ok(());
    }
    let in_conf = datovka_core::legacy::conf::load(s.dir())
        .map_err(e)?
        .iter()
        .any(|a| a.username == acc.username && a.password.is_some());
    if in_conf {
        datovka_core::legacy::conf::set_password(s.dir(), &acc.username, new).map_err(e)
    } else {
        datovka_core::legacy::secrets::set_password(&acc.username, acc.test_env, new).map_err(e)
    }
}

/// Imports a ZFO file into the box it belongs to (recipient: received,
/// sender: sent). Returns the username, or an error when no box matches.
#[no_mangle]
pub extern "C" fn dk_import_zfo(
    dir: *const c_char,
    path: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    use datovka_core::model::Direction;
    respond((|| {
        let s = store(dir)?;
        let data = std::fs::read(arg(path)?).map_err(e)?;
        let msg = datovka_core::zfo::parse_message(&data).map_err(e)?;
        let env = &msg.envelope;
        for acc in s.accounts().map_err(e)? {
            let Some(own) = s.box_info(&acc).map_err(e)?.box_id else {
                continue;
            };
            let dir = if env.recipient_box_id.as_deref() == Some(own.as_str()) {
                Direction::Received
            } else if env.sender_box_id.as_deref() == Some(own.as_str()) {
                Direction::Sent
            } else {
                continue;
            };
            return match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
                lock::Acquire::Acquired(l) => {
                    let added = s.insert_message(&l, &acc, dir, &data, None).map_err(e)?;
                    Ok(json!({ "username": acc.username, "added": added, "dm_id": env.dm_id }))
                }
                lock::Acquire::HeldBy(i) => {
                    Err(format!("data právě upravuje zařízení {}", i.device))
                }
            };
        }
        Err(format!(
            "zpráva {} nepatří žádné z vašich schránek",
            env.dm_id
        ))
    })())
}

fn copy_dir(from: &std::path::Path, to: &std::path::Path) -> std::io::Result<u64> {
    std::fs::create_dir_all(to)?;
    let mut n = 0;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_s = name.to_string_lossy();
        // Skip temporary and lock files.
        if name_s.starts_with(".datovka-zamek") || name_s.ends_with(".tmp") {
            continue;
        }
        let p = entry.path();
        if p.is_dir() {
            n += copy_dir(&p, &to.join(&name))?;
        } else {
            std::fs::copy(&p, to.join(&name))?;
            n += 1;
        }
    }
    Ok(n)
}

/// Copies the whole data folder into `target/DATOVKA-zaloha-<date>`.
#[no_mangle]
pub extern "C" fn dk_backup(dir: *const c_char, target: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let target = arg(target)?;
        // A file name ending in .zip gets one ZIP file, anything else a folder.
        if target.to_lowercase().ends_with(".zip") {
            let n = datovka_core::legacy::backup::zip_dir(s.dir(), std::path::Path::new(&target))
                .map_err(e)?;
            return Ok(json!({ "path": target, "files": n }));
        }
        let stamp = chrono_like_now();
        let out = std::path::Path::new(&target).join(format!("DATOVKA-zaloha-{stamp}"));
        let n = copy_dir(s.dir(), &out).map_err(e)?;
        Ok(json!({ "path": out, "files": n }))
    })())
}

/// Replaces the data folder content with a backup. The current data are
/// first saved next to the backup as `DATOVKA-pred-obnovou-<date>`.
#[no_mangle]
pub extern "C" fn dk_restore(
    dir: *const c_char,
    backup: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let picked = std::path::PathBuf::from(arg(backup)?);
        // A ZIP is unpacked next to the data first; the safety copy goes there
        // too, as a picked file may sit in a temporary folder (phones).
        let beside = s.dir().parent().unwrap_or(s.dir()).to_path_buf();
        let unpacked = beside.join(format!(".datovka-obnova-{}", chrono_like_now()));
        let zipped = picked.is_file();
        let backup = if zipped {
            datovka_core::legacy::backup::unzip_backup(&picked, &unpacked).map_err(e)?
        } else {
            picked.clone()
        };
        if !backup.join("dsgui.conf").exists() {
            return Err("vybraná složka není záloha DATOVKY (chybí dsgui.conf)".into());
        }
        let l = match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(l) => l,
            lock::Acquire::HeldBy(i) => {
                return Err(format!("data právě upravuje zařízení {}", i.device))
            }
        };
        let safety = if zipped {
            beside.clone()
        } else {
            backup.parent().unwrap_or(&backup).to_path_buf()
        }
        .join(format!("DATOVKA-pred-obnovou-{}", chrono_like_now()));
        copy_dir(s.dir(), &safety).map_err(e)?;
        let n = copy_dir(&backup, s.dir()).map_err(e)?;
        drop(l);
        if zipped {
            let _ = std::fs::remove_dir_all(&unpacked);
        }
        Ok(json!({ "files": n, "safety_copy": safety }))
    })())
}

fn chrono_like_now() -> String {
    chrono::Local::now().format("%Y-%m-%d_%H%M").to_string()
}

/// Saves the order of accounts; `order` is a JSON array of usernames.
#[no_mangle]
pub extern "C" fn dk_reorder(
    dir: *const c_char,
    order: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let order: Vec<String> = serde_json::from_str(&arg(order)?).map_err(e)?;
        match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(_l) => {
                datovka_core::legacy::conf::reorder(s.dir(), &order).map_err(e)?;
                Ok(json!(true))
            }
            lock::Acquire::HeldBy(i) => Err(format!(
                "data právě upravuje zařízení {}, pořadí se neuložilo",
                i.device
            )),
        }
    })())
}

/// Message metadata and attachments for an AI analysis.
fn ai_input(
    s: &LegacyStore,
    acc: &LegacyAccount,
    dm_id: i64,
) -> Result<(String, Vec<datovka_core::ai::AiFile>), String> {
    let m = s
        .messages(acc)
        .map_err(e)?
        .into_iter()
        .find(|m| m.dm_id == dm_id)
        .ok_or("zpráva nenalezena")?;
    let meta = format!(
        "Věc: {}\nOdesílatel: {}\nAdresát: {}\nDoručeno: {}\nČ. j. odesílatele: {}",
        m.annotation.unwrap_or_default(),
        m.sender.unwrap_or_default(),
        m.recipient.unwrap_or_default(),
        m.delivery_time
            .map(|t| t
                .with_timezone(&chrono::Local)
                .format("%Y-%m-%d %H:%M")
                .to_string())
            .unwrap_or_default(),
        m.sender_ref_number.unwrap_or_default(),
    );
    let mut files = Vec::new();
    for a in s.attachments(acc, dm_id).map_err(e)? {
        files.push(datovka_core::ai::AiFile {
            data: s.attachment_content(acc, dm_id, a.id).map_err(e)?,
            name: a.file_name,
            mime: a.mime_type,
        });
    }
    Ok((meta, files))
}

/// AI analysis of a message's attachments via the Claude API.
#[no_mangle]
pub extern "C" fn dk_ai_analyze(
    dir: *const c_char,
    username: *const c_char,
    dm_id: i64,
    api_key: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let (meta, files) = ai_input(&s, &acc, dm_id)?;
        block_on(datovka_core::ai::analyze(&arg(api_key)?, &meta, &files))?.map_err(e)
    })())
}

/// Prompt for the local Claude Code CLI: attachments are written to
/// `out_dir` and the prompt refers to them. Returns `{prompt, files}`.
#[no_mangle]
pub extern "C" fn dk_ai_cli_prompt(
    dir: *const c_char,
    username: *const c_char,
    dm_id: i64,
    out_dir: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let (meta, files) = ai_input(&s, &acc, dm_id)?;
        let out = std::path::PathBuf::from(arg(out_dir)?);
        std::fs::create_dir_all(&out).map_err(e)?;
        let mut paths = Vec::new();
        for f in files {
            let p = out.join(f.name.replace(['/', '\\', ':'], "_"));
            std::fs::write(&p, &f.data).map_err(e)?;
            paths.push(p.to_string_lossy().into_owned());
        }
        Ok(json!({
            "prompt": datovka_core::ai::cli_prompt(&meta, &paths),
            "files": paths,
        }))
    })())
}

/// Extracts the JSON answer from text printed by the CLI.
#[no_mangle]
pub extern "C" fn dk_ai_parse_text(text: *const c_char) -> *mut c_char {
    respond((|| {
        datovka_core::ai::json_from_text(&arg(text)?).map_err(e)
    })())
}

/// Adds an account to `dsgui.conf`. `request` is JSON: name, username,
/// login (`password`, `password_totp`, `password_hotp`, `mobile_key`,
/// `certificate`), secret, test_env.
#[no_mangle]
pub extern "C" fn dk_account_add(
    dir: *const c_char,
    request: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let r: Value = serde_json::from_str(&arg(request)?).map_err(e)?;
        let get = |k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let login: LoginMethod =
            serde_json::from_value(r.get("login").cloned().unwrap_or(json!("password")))
                .map_err(e)?;
        let username = get("username");
        if username.trim().is_empty() {
            return Err("chybí uživatelské jméno".into());
        }
        let secret = get("secret");
        match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(_l) => datovka_core::legacy::conf::add_account(
                s.dir(),
                &get("name"),
                username.trim(),
                login,
                Some(secret.as_str()),
                r.get("test_env").and_then(Value::as_bool).unwrap_or(false),
            )
            .map_err(e)?,
            lock::Acquire::HeldBy(i) => return Err(format!("data upravuje zařízení {}", i.device)),
        }
        Ok(json!(true))
    })())
}

/// Changes the account's display name in `dsgui.conf` (`name=`). The official
/// box name in ISDS is not touched.
#[no_mangle]
pub extern "C" fn dk_account_rename(
    dir: *const c_char,
    username: *const c_char,
    name: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let username = arg(username)?;
        let name = arg(name)?.trim().to_string();
        if name.is_empty() || name.contains(['\n', '\r']) {
            return Err("jméno schránky nesmí být prázdné".into());
        }
        match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(_l) => {
                datovka_core::legacy::conf::set_value(s.dir(), &username, "name", &name)
                    .map_err(e)?
            }
            lock::Acquire::HeldBy(i) => return Err(format!("data upravuje zařízení {}", i.device)),
        }
        Ok(json!(true))
    })())
}

/// Switches the account's login method. `request` is JSON: login (as in
/// [dk_account_add]) and an optional secret. The current session ends.
#[no_mangle]
pub extern "C" fn dk_account_set_login(
    dir: *const c_char,
    username: *const c_char,
    request: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let username = arg(username)?;
        let r: Value = serde_json::from_str(&arg(request)?).map_err(e)?;
        let login: LoginMethod =
            serde_json::from_value(r.get("login").cloned().unwrap_or(json!("password")))
                .map_err(e)?;
        let secret = r.get("secret").and_then(Value::as_str);
        match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(_l) => {
                datovka_core::legacy::conf::set_login(s.dir(), &username, login, secret)
                    .map_err(e)?
            }
            lock::Acquire::HeldBy(i) => return Err(format!("data upravuje zařízení {}", i.device)),
        }
        sessions().lock().unwrap().remove(&username);
        Ok(json!(true))
    })())
}

/// Removes an account from `dsgui.conf`; its messages stay on disk.
#[no_mangle]
pub extern "C" fn dk_account_remove(
    dir: *const c_char,
    username: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let username = arg(username)?;
        match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(_l) => {
                datovka_core::legacy::conf::remove_account(s.dir(), &username).map_err(e)?
            }
            lock::Acquire::HeldBy(i) => return Err(format!("data upravuje zařízení {}", i.device)),
        }
        sessions().lock().unwrap().remove(&username);
        Ok(json!(true))
    })())
}

/// Mobile Datovka databases found in a folder (e.g. an unpacked transfer ZIP).
#[no_mangle]
pub extern "C" fn dk_mobile_scan(folder: *const c_char) -> *mut c_char {
    respond((|| {
        let dbs =
            datovka_core::legacy::mobile::scan(std::path::Path::new(&arg(folder)?)).map_err(e)?;
        Ok(json!(dbs
            .into_iter()
            .map(|d| json!({
                "username": d.username,
                "test_env": d.test_env,
                "path": d.path,
                "messages": d.messages,
            }))
            .collect::<Vec<_>>()))
    })())
}

/// Imports one mobile database into the account with the same username.
#[no_mangle]
pub extern "C" fn dk_mobile_import(
    dir: *const c_char,
    db: *const c_char,
    username: *const c_char,
    device: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let db = std::path::PathBuf::from(arg(db)?);
        match lock::acquire(s.dir(), &arg(device)?).map_err(e)? {
            lock::Acquire::Acquired(l) => {
                let r = s.import_mobile(&l, &acc, &db).map_err(e)?;
                Ok(json!({
                    "total": r.total,
                    "imported": r.imported,
                    "already_present": r.already_present,
                    "missing_zfo": r.missing_zfo,
                    "failed": r.failed.iter().map(|(id, m)| format!("{id}: {m}")).collect::<Vec<_>>(),
                }))
            }
            lock::Acquire::HeldBy(i) => Err(format!("data upravuje zařízení {}", i.device)),
        }
    })())
}

/// Certificate login: reads the account's PKCS#12 file (`p12file` in
/// dsgui.conf, or `p12_path` when given) with the passphrase typed by the
/// user and keeps the session for this run.
#[no_mangle]
pub extern "C" fn dk_login_cert(
    dir: *const c_char,
    username: *const c_char,
    p12_path: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = unlocked(&s.account(&arg(username)?).map_err(e)?)?;
        let path = arg(p12_path)?;
        let path = if path.is_empty() {
            acc.p12_file
                .clone()
                .ok_or("schránka nemá nastavený soubor s certifikátem")?
        } else {
            path
        };
        let p12 = std::fs::read(&path).map_err(|err| format!("{path}: {err}"))?;
        let c = cert_client(&acc, &p12, &arg(passphrase)?)?;
        // Check the login right away.
        block_on(c.owner_info())?.map_err(e)?;
        sessions().lock().unwrap().insert(acc.username.clone(), c);
        Ok(json!(true))
    })())
}

// ---------------------------------------------------------------------------
// Records management service ("spisová služba")
// ---------------------------------------------------------------------------

use datovka_core::model::Direction;
use datovka_core::records;

/// PIN for the records management token: `Some(pin)` when a PIN is
/// configured and entered, `None` when no PIN is configured. Errors when a
/// PIN is configured but not entered yet.
fn rm_pin(s: &LegacyStore) -> Result<Option<String>, String> {
    let text = std::fs::read_to_string(s.dir().join("dsgui.conf")).unwrap_or_default();
    if !datovka_core::legacy::pin::pin_configured(&text) {
        return Ok(None);
    }
    pin()
        .lock()
        .unwrap()
        .clone()
        .map(Some)
        .ok_or_else(|| format!("{SESSION_EXPIRED}: nastavení je chráněné PINem, zadejte PIN"))
}

fn rm_client(s: &LegacyStore) -> Result<records::Client, String> {
    let set = records::load_settings(s.dir()).map_err(e)?;
    if !set.is_valid() {
        return Err("spisová služba není nastavena".into());
    }
    let pin = pin().lock().unwrap().clone();
    let token = set.token(pin.as_deref()).map_err(e)?.ok_or_else(|| {
        format!("{SESSION_EXPIRED}: přístupový token je chráněný PINem, zadejte PIN")
    })?;
    records::Client::new(&set.url, &token).map_err(e)
}

/// Records management settings without the token:
/// `{"url", "configured", "encrypted", "token_available"}`.
#[no_mangle]
pub extern "C" fn dk_rm_settings_get(dir: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let set = records::load_settings(s.dir()).map_err(e)?;
        let pin = pin().lock().unwrap().clone();
        let available = set.is_valid() && set.token(pin.as_deref()).ok().flatten().is_some();
        Ok(json!({
            "url": set.url,
            "configured": set.is_valid(),
            "encrypted": set.encrypted(),
            "token_available": available,
        }))
    })())
}

/// Saves `{"url", "token"}` into `[records_management]` of dsgui.conf
/// (token encrypted with the PIN when one is set). An empty token keeps the
/// stored one; an empty URL removes the settings. Cached locations are
/// dropped when the URL changes, as the original does.
#[no_mangle]
pub extern "C" fn dk_rm_settings_set(dir: *const c_char, json: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let v: Value = serde_json::from_str(&arg(json)?).map_err(e)?;
        let url = v["url"].as_str().unwrap_or("").trim().to_string();
        let mut token = v["token"].as_str().unwrap_or("").trim().to_string();
        let old = records::load_settings(s.dir()).map_err(e)?;
        if url.is_empty() {
            records::save_settings(s.dir(), "", "", None).map_err(e)?;
            records::db_clear(s.dir(), true).map_err(e)?;
            return Ok(json!(true));
        }
        let pin = rm_pin(&s)?;
        if token.is_empty() {
            token = old
                .token(pin.as_deref())
                .map_err(e)?
                .ok_or("zadejte přístupový token")?;
        }
        records::save_settings(s.dir(), &url, &token, pin.as_deref()).map_err(e)?;
        if old.url != url {
            records::db_clear(s.dir(), false).map_err(e)?;
        }
        Ok(json!(true))
    })())
}

/// Calls `service_info` with the saved settings; returns
/// `{"name", "token_name", "logo_svg"}` (logo as base64) and caches it in
/// records_management.db. Blocking.
#[no_mangle]
pub extern "C" fn dk_rm_info(dir: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let c = rm_client(&s)?;
        let info = block_on(c.service_info())?.map_err(e)?;
        let url = records::load_settings(s.dir()).map_err(e)?.url;
        records::db_set_service_info(s.dir(), &url, &info).map_err(e)?;
        serde_json::to_value(&info).map_err(e)
    })())
}

/// Calls `upload_hierarchy`; returns the root node
/// `{"name", "id", "metadata", "case_id"?, "court_case_id"?, "sub": [...]}`.
/// Blocking.
#[no_mangle]
pub extern "C" fn dk_rm_hierarchy(dir: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let c = rm_client(&s)?;
        let root = block_on(c.upload_hierarchy())?.map_err(e)?;
        serde_json::to_value(&root).map_err(e)
    })())
}

/// Uploads the signed message (ZFO) as `DDZ_<id>.zfo` / `ODZ_<id>.zfo`
/// into the hierarchy nodes `node_ids_json` (JSON array of strings).
/// Returns `{"id", "file_name", "locations"}` and records the locations in
/// records_management.db. Blocking.
#[no_mangle]
pub extern "C" fn dk_rm_upload(
    dir: *const c_char,
    username: *const c_char,
    dm_id: i64,
    node_ids_json: *const c_char,
) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let acc = s.account(&arg(username)?).map_err(e)?;
        let ids: Vec<String> = serde_json::from_str(&arg(node_ids_json)?).map_err(e)?;
        if ids.is_empty() {
            return Err("vyberte umístění ve spisové službě".into());
        }
        let zfo = s
            .zfo(&acc, dm_id)
            .map_err(e)?
            .ok_or("zpráva není stažená celá (chybí ZFO)")?;
        // Exports::dmTypePrefix() of the original.
        let direction = s
            .messages(&acc)
            .map_err(e)?
            .into_iter()
            .find(|m| m.dm_id == dm_id)
            .map(|m| m.direction);
        let prefix = match direction {
            Some(Direction::Received) => "DDZ",
            Some(Direction::Sent) => "ODZ",
            None => "DZ",
        };
        let name = format!("{prefix}_{dm_id}.zfo");
        let c = rm_client(&s)?;
        let r = block_on(c.upload_file(&ids, &name, &zfo))?.map_err(e)?;
        let Some(id) = r.id.clone().filter(|i| !i.is_empty()) else {
            let why = r.error.map(|x| x.to_string()).unwrap_or_default();
            return Err(format!("zprávu {dm_id} se nepodařilo nahrát: {why}"));
        };
        if !r.locations.is_empty() {
            records::db_set_locations(s.dir(), dm_id, &r.locations).map_err(e)?;
        }
        Ok(json!({ "id": id, "file_name": name, "locations": r.locations }))
    })())
}

/// Asks `stored_files` where the messages `dm_ids_json` (JSON array of
/// integers) are stored; updates records_management.db and returns
/// `[{"dm_id", "locations"}]` (empty locations = not stored). Blocking.
#[no_mangle]
pub extern "C" fn dk_rm_stored(dir: *const c_char, dm_ids_json: *const c_char) -> *mut c_char {
    respond((|| {
        let s = store(dir)?;
        let ids: Vec<i64> = serde_json::from_str(&arg(dm_ids_json)?).map_err(e)?;
        if ids.is_empty() {
            return Ok(json!([]));
        }
        let c = rm_client(&s)?;
        let entries = block_on(c.stored_messages(&ids))?.map_err(e)?;
        for en in &entries {
            records::db_set_locations(s.dir(), en.dm_id, &en.locations).map_err(e)?;
        }
        Ok(json!(entries
            .iter()
            .map(|en| json!({ "dm_id": en.dm_id, "locations": en.locations }))
            .collect::<Vec<_>>()))
    })())
}

/// Android: the key for the passwords file (hex of 32 bytes, kept by the
/// app in the Android Keystore) and the file in the app's own storage.
#[no_mangle]
pub extern "C" fn dk_secret_key(key: *const c_char, path: *const c_char) -> *mut c_char {
    respond((|| {
        let hex = arg(key)?;
        let raw: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| hex.get(i..i + 2).and_then(|b| u8::from_str_radix(b, 16).ok()))
            .collect::<Option<_>>()
            .ok_or("klíč není v šestnáctkovém zápisu")?;
        let key: [u8; 32] = raw.try_into().map_err(|_| "klíč musí mít 32 bajtů".to_string())?;
        #[cfg(target_os = "android")]
        datovka_core::legacy::secrets::use_file_store(key, std::path::PathBuf::from(arg(path)?));
        #[cfg(not(target_os = "android"))]
        let _ = (key, path);
        Ok(json!(true))
    })())
}

/// A secret of this device (an API key) from the system store, or null.
#[no_mangle]
pub extern "C" fn dk_secret_get(name: *const c_char) -> *mut c_char {
    respond((|| Ok(json!(datovka_core::legacy::secrets::app_secret(&arg(name)?))))())
}

/// Stores a secret of this device; an empty value deletes it.
#[no_mangle]
pub extern "C" fn dk_secret_set(name: *const c_char, value: *const c_char) -> *mut c_char {
    respond((|| {
        datovka_core::legacy::secrets::set_app_secret(&arg(name)?, &arg(value)?).map_err(e)?;
        Ok(json!(true))
    })())
}

/// Sets the proxy URL for all connections (empty = system settings).
#[no_mangle]
pub extern "C" fn dk_set_proxy(url: *const c_char) -> *mut c_char {
    respond((|| {
        let url = arg(url)?;
        if !url.trim().is_empty() {
            reqwest_check(&url)?;
        }
        datovka_core::set_proxy(Some(url));
        Ok(json!(true))
    })())
}

fn reqwest_check(url: &str) -> Result<(), String> {
    url.parse::<std::net::SocketAddr>()
        .map(|_| ())
        .or_else(|_| {
            if url.contains("://") {
                Ok(())
            } else {
                Err(format!(
                    "neplatná adresa proxy: {url} (např. http://proxy.firma.cz:3128)"
                ))
            }
        })
}

#[cfg(not(target_os = "android"))]
fn cert_client(acc: &LegacyAccount, p12: &[u8], passphrase: &str) -> Result<Client, String> {
    Client::with_certificate(
        &acc.username,
        acc.password.as_deref(),
        p12,
        passphrase,
        acc.test_env,
    )
    .map_err(e)
}

#[cfg(target_os = "android")]
fn cert_client(_: &LegacyAccount, _: &[u8], _: &str) -> Result<Client, String> {
    Err("přihlášení certifikátem není na Androidu podporováno".into())
}
