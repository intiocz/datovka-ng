use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use datovka_core::isds::SearchType;
use datovka_core::legacy::{lock, sync, LegacyStore};

#[derive(Parser)]
#[command(
    name = "datovka",
    about = "Klient datových schránek (data původní Datovky)"
)]
struct Cli {
    /// Složka s daty, výchozí ~/.dsgui.
    #[arg(long, env = "DATOVKA_DIR")]
    dir: Option<PathBuf>,
    /// Název tohoto zařízení pro zámek zápisu.
    #[arg(long, env = "DATOVKA_DEVICE", default_value = "cli")]
    device: String,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Vypíše schránky a počty zpráv.
    Accounts,
    /// Vypíše zprávy schránky.
    List {
        user: String,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Stáhne nové zprávy schránky z ISDS (přihlášení = doručení čekajících zpráv).
    Sync {
        user: String,
        /// Převzít zámek, i když ho drží jiné zařízení.
        #[arg(long)]
        take: bool,
    },
    /// Vyhledá schránky v adresáři ISDS.
    Find {
        /// Schránka, kterou se přihlásit.
        user: String,
        text: String,
        /// Jen orgány veřejné moci.
        #[arg(long)]
        ovm: bool,
        /// Hledat podle IČO.
        #[arg(long)]
        ico: bool,
    },
    /// Zobrazí obsah ZFO souboru.
    Show { zfo: PathBuf },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let dir = cli
        .dir
        .or_else(LegacyStore::default_dir)
        .context("neznámý domovský adresář")?;
    let store = LegacyStore::new(dir);

    match cli.cmd {
        Cmd::Accounts => {
            for acc in store.accounts()? {
                let info = store.box_info(&acc)?;
                println!(
                    "{:<8} {:<12} {:<30} {:>5} zpráv  {:?}",
                    acc.username,
                    info.box_id.unwrap_or_default(),
                    acc.name,
                    store.messages(&acc)?.len(),
                    acc.login,
                );
            }
        }
        Cmd::List { user, limit } => {
            let acc = store.account(&user)?;
            for m in store.messages(&acc)?.into_iter().take(limit) {
                let who = match m.direction {
                    datovka_core::model::Direction::Received => m.sender,
                    datovka_core::model::Direction::Sent => m.recipient,
                };
                println!(
                    "{} {:>11} {} {:<35} {}",
                    if m.read_locally { ' ' } else { '•' },
                    m.dm_id,
                    m.delivery_time
                        .map(|t| t.format("%Y-%m-%d").to_string())
                        .unwrap_or_default(),
                    who.unwrap_or_default(),
                    m.annotation.unwrap_or_default()
                );
            }
        }
        Cmd::Sync { user, take } => {
            let acc = store.account(&user)?;
            let l = if take {
                lock::take(store.dir(), &cli.device)?
            } else {
                match lock::acquire_wait(
                    store.dir(),
                    &cli.device,
                    std::time::Duration::from_secs(180),
                )? {
                    lock::Acquire::Acquired(l) => l,
                    lock::Acquire::HeldBy(i) => anyhow::bail!(
                        "data právě zapisuje zařízení {}. Čtení funguje. Převzetí: datovka sync --take",
                        i.device
                    ),
                }
            };
            let report = sync::sync_account(&store, &l, &acc).await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Cmd::Find {
            user,
            text,
            ovm,
            ico,
        } => {
            let acc = store.account(&user)?;
            let client = sync::client_for(&acc)?;
            let kind = if ico {
                SearchType::Ico
            } else {
                SearchType::General
            };
            let page = client.search_boxes(&text, kind, ovm, 0).await?;
            for e in page.entries {
                println!(
                    "{}  {:<50}  {}",
                    e.box_id,
                    e.name.unwrap_or_default(),
                    e.address.unwrap_or_default()
                );
            }
            println!("celkem {}", page.total);
        }
        Cmd::Show { zfo } => {
            let data = std::fs::read(&zfo)?;
            let msg = datovka_core::zfo::parse_message(&data)?;
            println!("{}", serde_json::to_string_pretty(&msg.envelope)?);
            for a in msg.attachments {
                println!("příloha: {} ({} B)", a.file_name, a.content.len());
            }
        }
    }
    Ok(())
}
