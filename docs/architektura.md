# Architektura

```
┌──────────────── app/ (Flutter, Dart) ────────────────┐
│ ui/        obrazovky: sidebar, seznam, detail,       │
│            psaní zprávy, adresář, přihlášení         │
│ data/      AppState (stav UI), CoreBridge (dart:ffi) │
└───────────────────────┬──────────────────────────────┘
                        │ C ABI, JSON řetězce
┌───────────────────────▼──────── ffi/ (Rust, cdylib) ─┐
│ dk_accounts, dk_messages, dk_sync, dk_sync_sent,     │
│ dk_send, dk_check_files, dk_op, dk_keep_alive, …     │
└───────────────────────┬──────────────────────────────┘
┌───────────────────────▼──────── core/ (Rust) ────────┐
│ isds/     SOAP klient ISDS (dz, dx, df, DsManage,    │
│           VoDZ, arch), pravidla příloh (rules.rs)    │
│ legacy/   data původní Datovky: dsgui.conf, SQLite,  │
│           zápis stažených zpráv, zámek, synchronizace│
│ zfo, ber  čtení podepsaných zpráv (CMS/BER)          │
│ xml       XML bez závislosti na jmenných prostorech  │
└──────────────────────────────────────────────────────┘
cli/   příkazová řádka `datovka` nad core
```

## Data

DATOVKA zachovává formát dat původní Datovky (`~/.dsgui`):

- `dsgui.conf` (INI): sekce `[credentials]`, `[credentials2]`, … s `username`,
  `name`, `login_method` (`username`, `mep`, `hotp`, `totp`, `certificate`…),
  `password` a `mep_token` v base64, případně `pwd_alg`/`pwd_salt`/`pwd_iv`/`pwd_code`
  (šifrováno PINem). Parser: `core/src/legacy/conf.rs`.
- `messages.shelf.db`: tabulka `account_info` s klíčem `{username}___True` pro
  produkční prostředí (ID schránky, typ, vlastník).
- `{username}_{rok}___{0|1}.db`: zprávy rozdělené podle roku doručení (UTC),
  `inv` pro zprávy bez data, `0` produkce, `1` test. Hlavní tabulky:
  - `messages`: obálka, časy `yyyy-MM-dd HH:mm:ss.zzz+00:00` v UTC,
  - `supplementary_message_data`: `message_type` (1 přijatá, 2 odeslaná),
    `read_locally`, `attsNum`, `download_date`, `specMessFlag` (podezřelá),
  - `files`: přílohy, `dmEncodedContent` jako base64 TEXT,
  - `raw_message_data`, `raw_delivery_info_data`: podepsané ZFO jako base64,
    uložené jako BLOB (původní aplikace váže `QByteArray::toBase64()`),
  - `events`, `process_state`, `hashes`, `certificate_data`,
    `message_certificate_data`.
- `tag.db`: štítky a poznámky původní aplikace.
- `datovka-doplnky.db`: jen Datovka NG (lhůty, koncepty, přehled razítek);
  původní aplikace ho ignoruje.

Zápis (`core/src/legacy/write.rs`) odpovídá `MessageDb::insertMessageEnvelope`
a souvisejícím funkcím původní aplikace, včetně `is_verified`,
`_origin = 'tReturnedMessage'`, otisku (`hashes`) a podpisového certifikátu,
aby původní aplikace zprávu brala jako celou staženou. Nová roční databáze
se vytvoří se schématem převzatým ze stávající databáze.

Stav uložených zpráv se při stahování porovná se seznamem z ISDS jako
v originálu. Při změně (dodáno → doručeno, trezor) se aktualizuje obálka,
znovu stáhne podepsaná doručenka a doplní události (`core/src/legacy/state.rs`).

Velkoobjemové zprávy (VoDZ) ukládá původní aplikace od verze 4.23 mimo
databázi a Datovka NG stejně: ve složce vedle roční databáze (její cesta bez
`.db`), podsložka `{dmID}/` s `DDZ_{dmID}.zfo` (přijatá) nebo
`ODZ_{dmID}.zfo` (odeslaná), doručenkou `DD_{dmID}.zfo` a přílohami
`ATT_{dmID}_{attNum}_{název}`. Sloupce `raw_message_data.data`,
`raw_delivery_info_data.data` a `files.dmEncodedContent` jsou pak NULL.
Soubory se píšou jako `….part` a přejmenují. Chybí-li soubor přílohy, čte se
příloha z podepsané zprávy, jako v originálu.

`database_dir` v sekci schránky v `dsgui.conf` říká, že původní aplikace
drží databáze zpráv té schránky v jiné složce (`messages.shelf.db`,
`tag.db` a ostatní zůstávají v archivu). Datovka NG ji čte i zapisuje tam.
Relativní cesta se počítá od archivu. Složka, která na tomto počítači
neexistuje (archiv sdílený z jiného počítače), znamená složku archivu.
Záloha ZIP přibalí databáze z takové složky do kořene.

### Synchronizace přes iCloud

SQLite není stavěné na souběžný zápis ze dvou zařízení přes synchronizovanou
složku. Proto:

1. **Zámek** `.datovka-zamek.json` (`core/src/legacy/lock.rs`): čtení je volné
   na všech zařízeních. Zápis si zámek vezme jen na dobu operace a pak ho
   pustí. Když právě zapisuje jiné zařízení, stahování až tři minuty počká.
   Zámek bez obnovení dvě minuty se bere jako spadlý a další zápis ho převezme.
   Tlačítko „Převzít“ a `datovka sync --take` jsou pro zámek, který ještě
   vypadá jako živý, ale zařízení je vypnuté.
2. **Krátká spojení**: každá operace otevře databázi a hned ji zavře, takže
   iCloud vidí vždy ucelené soubory.
3. Žurnál zůstává v režimu `DELETE` jako u původní aplikace (žádné `-wal`
   soubory, které by se synchronizovaly odděleně).

## ISDS

- Produkce `https://ws1.datovka.gov.cz/`, test `https://ws1.datovka-test.gov.cz/`.
- SOAP 1.1, jmenný prostor `http://isds.czechpoint.cz/v20`.
- `DS/dz` = operace se zprávami (stažení, odeslání), `DS/dx` = informace
  o zprávách (seznamy, doručenky, ověření), `DS/df` = vyhledávání,
  `DS/DsManage` = správa schránky.
- Přihlášení jménem a heslem přes HTTP Basic při každém volání na `ws1`.
- Certifikát: `ws1c…/cert/` (systémový, bez jména) nebo `ws1c…/certds/`
  (uživatelský s jménem a heslem).
- SMS, kód z aplikace a mobilní klíč: `www.datovka.gov.cz/as/processLogin?type=…&uri=…/apps/DS/dz`,
  dál session cookie a služby na `www.datovka.gov.cz/apps/DS/…`. Mobilní klíč
  vrací adresu `mepWsStateUpdate`, ze které se čte stav (1 čeká, 2 potvrzeno,
  3 odmítnuto nebo vypršelo). Sezení vyprší po 30 minutách nečinnosti,
  Datovka ho každých 25 minut udrží přes `DummyOperation`.
- Odpovědi mohou být MTOM/XOP (`multipart/related`), rozdělení řeší
  `core/src/isds/multipart.rs`.
- Chyby: `dmStatus`/`dbStatus` (kód `0000` = OK), SOAP Fault, hlavičky
  `X-Response-message-code`/`-text`.

| Operace | Služba | Použití |
|---|---|---|
| `GetOwnerInfoFromLogin` | DsManage | údaje o schránce |
| `GetPasswordInfo` | DsManage | expirace hesla |
| `GetListOfReceivedMessages` / `GetListOfSentMessages` | dx | seznamy zpráv |
| `SignedMessageDownload` / `SignedSentMessageDownload` | dz | podepsané zprávy |
| `GetSignedDeliveryInfo` | dx | doručenky |
| `MarkMessageAsDownloaded` | dx | označení přečtení v ISDS |
| `CreateMessage` | dz | odeslání |
| `ISDSSearch3` | df | adresář schránek |

Úplný přehled operací a jejich stavu je v [isds-api.md](isds-api.md).
Doručení přihlášením způsobuje jen `GetListOfReceivedMessages`; stažení jen
odeslaných zpráv (např. hned po odeslání) nic nedoručí.

## Zásady chování

- Nic na pozadí neotevírá okna a nebere fokus.
- Interaktivní přihlášení (SMS, OTP, mobilní klíč) se na pozadí nikdy
  nespouští a neposílají se opakovaná upozornění.
- Hesla nikdy neopouštějí jádro. Rozhraní FFI vrací jen příznak, zda jsou
  uložená.
- Volání sítě běží v Dartu v samostatném isolate (`CoreBridge.callAsync`), UI
  nezamrzá.
