# Architektura

```
┌──────────────── app/ (Flutter, Dart) ────────────────┐
│ ui/        obrazovky: sidebar, seznam, detail,       │
│            psaní zprávy, adresář, přihlášení         │
│ data/      AppState (stav UI), CoreBridge (dart:ffi) │
└───────────────────────┬──────────────────────────────┘
                        │ C ABI, JSON řetězce
┌───────────────────────▼──────── ffi/ (Rust, cdylib) ─┐
│ dk_accounts, dk_messages, dk_attachments, dk_save_*, │
│ dk_set_read, dk_sync, dk_search, dk_send, dk_free    │
└───────────────────────┬──────────────────────────────┘
┌───────────────────────▼──────── core/ (Rust) ────────┐
│ isds/     SOAP klient ISDS (dz, dx, df, DsManage)    │
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
    `read_locally`, `attsNum`, `download_date`,
  - `files`: přílohy, `dmEncodedContent` jako base64 TEXT,
  - `raw_message_data`, `raw_delivery_info_data`: podepsané ZFO jako base64,
    uložené jako BLOB (původní aplikace váže `QByteArray::toBase64()`),
  - `events`, `process_state`.

Zápis (`core/src/legacy/write.rs`) odpovídá `MessageDb::insertMessageEnvelope`
a souvisejícím funkcím původní aplikace. Nová roční databáze se vytvoří se
schématem převzatým ze stávající databáze.

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
- SMS, kód z aplikace a mobilní klíč: `www.datovka.gov.cz/as/processLogin?type=…&uri=…/apps/DS/dz`,
  dál session cookie a služby na `www.datovka.gov.cz/apps/DS/…`. Mobilní klíč
  vrací adresu `mepWsStateUpdate`, ze které se čte stav (1 čeká, 2 potvrzeno,
  3 odmítnuto nebo vypršelo).
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
| `ISDSSearch2` | df | adresář schránek |

## Zásady chování

- Nic na pozadí neotevírá okna a nebere fokus.
- Interaktivní přihlášení (SMS, OTP, mobilní klíč) se na pozadí nikdy
  nespouští a neposílají se opakovaná upozornění.
- Hesla nikdy neopouštějí jádro. Rozhraní FFI vrací jen příznak, zda jsou
  uložená.
- Volání sítě běží v Dartu v samostatném isolate (`CoreBridge.callAsync`), UI
  nezamrzá.
