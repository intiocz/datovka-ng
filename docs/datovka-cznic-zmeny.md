# Změny v Datovce CZ.NIC 2023–2026 a co znamenají pro Datovku NG

Zdroj: `reference/datovka-qt/ChangeLog` (do 4.29.2) a aktuální ChangeLog
z větve `develop` na gitlab.nic.cz/datovka/datovka (do 4.29.6, zatím
nevydaná). Na Macu je nainstalovaná 4.29.5. Stav k 30. 10. 2026.

## 1. Přehled verzí

| Verze | Datum | Hlavně |
|---|---|---|
| 4.22.0 | 2023-02-15 | typ schránky PFO_REQ, `GetMessageAuthor2`, volba co prozradit o odesílateli |
| 4.22.1 | 2023-04-19 | počet nepřečtených u sbaleného uzlu |
| 4.23.0 | 2023-11-28 | **velkoobjemové zprávy (VoDZ)**, **ukládání obsahu do souborů vedle databáze**, typy PFO_ARCH/AIAT/AZI |
| 4.23.1–4.23.3 | 12/2023–1/2024 | „účet“ → „datová schránka“, odesílání VoDZ, průběh nahrávání |
| 4.23.4 | 2024-01-23 | ZIP v běžné zprávě (MIME), max. 50 příloh, rozšířený seznam povolených typů |
| 4.23.5–4.23.8 | 2–5/2024 | mobilní klíč na novém macOS, pády detailu zprávy, CLI pozná VoDZ sám |
| 4.24.0 | 2024-06-18 | CLI export/import zpráv, PDF obálky jako v mobilu, VoDZ obálka při synchronizaci, varování u změněného PDF, timeout 15 min |
| 4.24.1–4.24.2 | 7–9/2024 | omezení hledání datem, ID schránek v přehledu korespondence, e-podání omylem jako VoDZ, nový typ události kreditu |
| 4.25.0 | 2024-12-17 | **udržování sezení** (HOTP, TOTP, mobilní klíč), **bezpečný zápis dsgui.conf**, témata |
| 4.26.0 | 2025-04-01 | nový dialog štítků, **nástroj na záchranu poškozených databází**, škálování písma, MTOM/XOP pro VoDZ, oprava duplicit příloh u VoDZ |
| 4.27.0 | 2025-09-24 | **`--conf-dir`**, **sledování časových razítek**, archivní razítka, export pro mobilní aplikaci, **změna adresáře databází** |
| 4.28.0 | 2026-01-20 | **čas s časovou zónou v databázích**, sloupce `specMessFlag` a `_dmFileSize`, **koncepty**, `AuthenticateMessage` místo `VerifyMessage` |
| 4.29.0 | 2026-04-07 | čtení databází mobilní aplikace 2.6.0, přetahování zpráv, celý archiv do přerazítkování |
| 4.29.1 | 2026-04-21 | **stažení zprávy hned po odeslání** (volba), automatické sledování razítek nových zpráv, nový způsob stavu mobilního klíče |
| 4.29.2 | 2026-05-26 | **poznámky ke zprávám v `tag.db`**, opravy CLI |
| 4.29.3 | 2026-07-08 | nové logo, víc vysvětlení u změny hesla, ARM balíček pro Mac v Rosettě, ikona v GNOME 49 |
| 4.29.4 | 2026-08-13 | e-mail přes Outlook (ActiveX), MAPI, oprava názvů příloh v Mail.app, **preferovaný způsob platby PDZ** |
| 4.29.5 | 2026-08-20 | oprava formátu ZFO přiloženého do e-mailu |
| 4.29.6 | nevydaná | **verze formátu v databázi zpráv (`_db_info`)**, filtr a řazení seznamu schránek, kód databází sdílený s mobilem |

## 2. Problémy, které řešili

### Data a databáze

| Problém (verze) | Týká se NG? | Proč |
|---|---|---|
| VoDZ zprávy, přílohy a doručenky ukládá originál jako soubory vedle databáze (4.23.0) | **ano** | NG čte obsah jen z databáze (`raw_message_data`, `files`). VoDZ zprávu staženou originálem NG zobrazí bez originálu a příloh. Soubory jsou ve složce `<jméno db bez .db>/<dmID>/` (`DDZ_…zfo`, `ODZ_…zfo`, `DD_…zfo`, `ATT_<dmID>_<č>_<název>`). |
| Duplicitní přílohy při opakovaném stažení VoDZ (4.26.0) | ověřit | NG stahuje VoDZ jinou cestou. Opakované stažení `redownload` maže a zapisuje znovu, duplicity by vzniknout neměly. |
| Obnova databází bez VoDZ (4.23.4), rozdělování monolitických databází (4.28.0) | ne | NG zálohu dělá po svém (ZIP celé složky). |
| Zápis `dsgui.conf` ve třech krocích, hledání kopie při chybějícím souboru (4.25.0) | částečně | NG píše přes `.dsgui.conf.tmp` a přejmenování a nechává `dsgui.conf.bak`. Když `dsgui.conf` chybí, NG kopii nehledá. |
| Chybové dialogy u nečitelné konfigurace a databází (4.26.0) | ověřit | Jak se NG chová u poškozeného `dsgui.conf` nebo databáze, není vyzkoušené. |
| Poškozené databáze, nástroj na záchranu (4.26.0) | ano | NG nic takového nemá. Na iCloudu je riziko poškození vyšší. |
| Čas v databázi s časovou zónou (4.28.0) | ne | NG zapisuje `…+00:00` a čte oba tvary (starší `2018-10-19 17:13:19.979000` i nový). Ověřeno na archivu. |
| Import z mobilní aplikace, formát 2.6.0 (4.29.0) | ověřit | NG import (`legacy/mobile.rs`) umí soubory vedle databáze. Na skutečné databázi z mobilní verze 2.6.x vyzkoušený není. |
| Verze formátu v databázi zpráv `_db_info` (4.29.6) | **ano** | Až vyjde, originál podle ní bude převádět databáze. NG zakládá novou roční databázi se schématem zkopírovaným z existující, tedy i s `_db_info`, ale bez řádku s verzí. Hlídat, jaký záznam originál čeká a jestli NG nezapisuje do novějšího formátu po staru. |

### ISDS a odesílání

| Problém (verze) | Týká se NG? | Proč |
|---|---|---|
| ZIP v běžné zprávě musí mít MIME typ (4.23.4) | ne | NG bere MIME typy z tabulky ISDS (od 1.0.5) a ZIP před odesláním kontroluje. Odeslání ZIPu na ISDS ale nikdo nezkoušel. |
| Max. 50 příloh, rozšířené povolené typy (4.23.4) | ne | NG od 1.0.5 kontroluje přílohy před odesláním podle aktuálních pravidel ISDS (nejvýš 100 příloh, z toho 10 ZIP/ASiC, povolené formáty). Originál má dosud 50. |
| E-podání omylem jako VoDZ (4.24.1) | ověřit | NG posílá jako VoDZ nad 20 MB. Žádosti e-podání jsou malé, riziko je malé. |
| Obálka VoDZ zpráv ze starých seznamů (4.24.0) | ne | NG takové seznamy nemá. |
| `AuthenticateMessage` místo `VerifyMessage` (4.28.0) | ne | NG už používá `AuthenticateMessage`, ověřeno na ostrém ISDS. |
| Nový typ události kreditu: obnova smazané zprávy (4.24.2) | částečně | NG ukazuje typ události tak, jak přijde. Hezký český název nemá. |
| Nové typy schránek PFO_REQ, PFO_ARCH, PFO_AIAT, PFO_AZI (2023) | ano, má | Jsou v `gov_services.dart`. Zobrazení typu schránky ověřit. |

### Přihlášení

| Problém (verze) | Týká se NG? | Proč |
|---|---|---|
| Smyčka mobilního klíče na novém macOS (4.23.5), nový způsob zjišťování stavu (4.29.1) | ověřit | NG mobilní klíč používá na ostrém ISDS. Jestli ISDS starý způsob zjišťování stavu nevypne, sledovat. |
| Sezení HOTP, TOTP a mobilního klíče vyprší (4.25.0) | ne | NG od 1.0.5 sezení udržuje jako originál (`DummyOperation` každých 25 minut). |

### Platformy

| Problém (verze) | Týká se NG? | Proč |
|---|---|---|
| Ikona v doku GNOME 49 (4.29.3) | ověřit | NG nastavuje `StartupWMClass`. V Ubuntu 24.04 ikona sedí, GNOME 49 nevyzkoušené. |
| Názvy příloh v e-mailu přes Mail.app, Outlook, MAPI (4.29.4–4.29.5) | ověřit | NG posílá e-mailem přes systém. S diakritikou v názvech nevyzkoušené. |
| ARM balíček na Macu v Rosettě (4.29.3) | ne | Balíček NG pro Mac je univerzální. |

## 3. Novinky

| Novinka (verze) | NG | Poznámka |
|---|---|---|
| Velkoobjemové zprávy, příjem i odesílání (4.23) | má | Od 1.0.4 v souborech vedle databáze jako originál. Odesílání neověřené na ISDS. |
| Průběh nahrávání příloh a odesílání (4.23.2) | nemá | NG ukazuje jen „odesílám“. |
| Zveřejnění identity odesílatele, `GetMessageAuthor2` (4.22) | má | |
| Varování, když se PDF příloha změnila po přiložení (4.24.0) | nemá | |
| Omezení hledání datem (4.24.1) | má | |
| ID schránek v přehledu korespondence (4.24.1) | ověřit | Zkontrolovat sloupce CSV. |
| Export a import zpráv v CLI (4.24.0) | částečně | CLI NG umí výpis, stažení, ZFO. Export a import zpráv ne. |
| Udržování sezení, seznam aktivních sezení (4.25.0) | částečně | Udržování ano (od 1.0.5, Nastavení → Stahování), seznam aktivních sezení ne. |
| Světlé a tmavé téma (4.25, 4.26) | má | Podle systému nebo ručně (Nastavení → Zobrazení). |
| Škálování písma (4.26.0) | má | Nastavení → Zobrazení: menší, běžná, větší (od 1.0.4). |
| „Co je nového“ (4.26.0) | má | Seznam změn v okně aktualizace. |
| Nástroj na záchranu poškozených databází (4.26.0) | nemá | |
| `--conf-dir`, změna adresáře databází (4.27.0) | má | NG umí jinou složku archivu a od 1.0.4 i `database_dir` u schránky. |
| Sledování a přerazítkování časových razítek (4.27–4.29) | částečně | NG má přehled expirace a obnovu. Seznam sledovaných zpráv originálu (`timestamp.db`) nečte ani nezapisuje, výsledky drží ve vlastním `datovka-doplnky.db`. |
| Archivní časová razítka v CMS (4.27.0) | ověřit | Ověřování podpisu v NG archivní razítka nejspíš nezná. Po přerazítkování by se mělo ukázat nejnovější razítko. |
| Export pro mobilní aplikaci (4.27.0) | ne | NG převádí archiv zálohou ZIP. |
| Koncepty (4.28.0, `drafts.db`) | částečně | NG má vlastní koncepty v `datovka-doplnky.db`. Koncepty originálu z `drafts.db` nevidí a ty z NG nevidí originál. |
| Stažení zprávy hned po odeslání (4.29.1) | má | Od 1.0.3, přepínač ve Stahování. |
| Přetahování zpráv ven z okna (4.29.0) | nemá | |
| Poznámky ke zprávám v `tag.db` (4.29.2) | má | Stejné tabulky jako originál. |
| Preferovaný způsob platby PDZ (4.29.4) | nemá | |
| Filtr a řazení seznamu schránek (4.29.6) | nemá | Hledání schránek jsme odložili. Řazení na telefonu je podle abecedy. |

## 4. Formát dat, který musíme hlídat

1. **Obsah ve složkách vedle databáze (od 4.23.0).** U VoDZ (a jinde, kde
   `raw_message_data.data` je NULL) leží obsah v
   `<rok-db bez .db>/<dmID>/`: `DDZ_<id>.zfo` (přijatá), `ODZ_<id>.zfo`
   (odeslaná), `DD_<id>.zfo` (doručenka), `ATT_<id>_<attNum>_<název>`
   (přílohy). NG to od 1.0.4 čte i zapisuje stejně.
2. **`database_dir` v `dsgui.conf` (u schránky).** Originál umí mít
   databáze schránky jinde než konfiguraci. NG ho od 1.0.4 respektuje
   (čtení, zápis i záloha).
3. **`_db_info` a verze formátu (4.29.6, nevydaná).** Tabulka
   `_db_info (id, entry_name, entry_json)` v každé databázi zpráv. Až
   vyjde, zjistit, jaký záznam píše a jak převádí, a NG naučit totéž.
4. **Čas s časovou zónou (4.28.0).** NG oba tvary čte, nové píše s `+00:00`.
   Hotovo.
5. **Sloupce `specMessFlag`, `_dmFileSize`, `dmVODZ`, `attsNum`,
   `attNum`.** NG je do starších databází doplňuje (`ADDED_COLUMNS`).
   `_dmFileSize` nevyplňuje, originál u běžných zpráv taky ne.
6. **Úplnost zprávy pro originál.** `is_verified`, `_origin =
   'tReturnedMessage'`, `hashes`, `message_certificate_data` NG zapisuje od
   1.0.4. Starší zprávy doplní při stahování.
7. **`timestamp.db` (sledování razítek, 4.27+).** Tabulky `identification`,
   `messages (tst_valid_to)`, `supplementary_message_data`. NG je nepoužívá.
   Když zprávu přerazítkuje NG, originál si v `timestamp.db` nechá staré
   datum platnosti. Zvážit zápis.
8. **`drafts.db` (koncepty, 4.28.0).** `drafts (username, test_env,
   location_key, jsonData)`. NG nečte.
9. **Databáze mobilní aplikace 2.6.0.** Import v NG vyzkoušet na skutečném
   exportu.

## 5. Doporučení (podle priority)

Hotovo: obsah VoDZ ve složkách a `database_dir` (1.0.4), udržování
sezení a kontrola příloh před odesláním (1.0.5).

1. **Sledovat vydání 4.29.6** a formát `_db_info`, včas NG přizpůsobit.
2. **Zapisovat platnost razítka do `timestamp.db`** po přerazítkování v NG,
   případně číst seznam sledovaných zpráv originálu.
3. Varování u PDF změněného po přiložení.
4. Koncepty z `drafts.db` aspoň zobrazit, aby se při přechodu neztratily.
5. Archivní časová razítka v ověření podpisu.
6. Drobnosti: preferovaný způsob platby PDZ, česky pojmenované události
   kreditu, průběh odesílání, záchrana poškozené databáze.
