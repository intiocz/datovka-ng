# Parita s původní Datovkou

Nová DATOVKA nesmí oproti původní (CZ.NIC, `reference/datovka-qt`) nic postrádat.
Seznam vychází z jejího zdrojového kódu.

Stav: ✅ hotovo · 🧪 hotovo, ale proti ISDS zatím neověřeno · ⬜ chybí

Všechny požadavky na ISDS se v testech kontrolují proti oficiálním XSD.
Čtecí operace jsou ověřené na ostrém ISDS (`core/tests/production.rs`,
29. 10. 2026), odeslání zprávy taky. Ostatní, co v ISDS něco mění, čeká
na testovací prostředí.

## Účty a přihlášení

| Funkce | Stav | Pozn. |
|---|---|---|
| Více schránek, přehledný seznam, změna pořadí | ✅ | pořadí v `dsgui.conf` |
| Přidání a odebrání schránky | ✅ | zápis do `dsgui.conf` |
| Jméno a heslo | ✅ | |
| Mobilní klíč | ✅ | jen na pokyn uživatele, bez opakovaných upozornění |
| Udržování přihlášení (SMS, kód, mobilní klíč) | 🧪 | každých 25 minut `DummyOperation` jako originál od 4.25; nic nedoručí; Nastavení → Stahování |
| Heslo + SMS kód | 🧪 | `type=totp` |
| Heslo + kód z aplikace (HOTP) | 🧪 | `type=hotp`; ISDS ho ruší, nově se nenabízí, stávající schránky upozorní |
| Certifikát, certifikát + heslo | 🧪 | PKCS#12, `ws1c` `certds/`/`hspis/`; ne na Androidu |
| Testovací prostředí | 🧪 | |
| Upozornění na konec platnosti hesla | ✅ | `GetPasswordInfo` ověřeno na ostrém ISDS |
| Změna hesla | 🧪 | uložené heslo se aktualizuje |
| Změna hesla v režimu OTP (SMS, kód z aplikace) | 🧪 | `ChangePasswordOTP`, `SendSMSCode` na `asws/changePassword` |
| Hesla šifrovaná PINem | ✅ | PBKDF2 + AES-256-CBC jako originál |
| Informace o vlastníkovi a uživateli | ✅ | `GetOwnerInfoFromLogin2`, `GetUserInfoFromLogin2` |
| Uživatelé schránky – výpis | ✅ | `GetDataBoxUsers2` |
| Uživatelé schránky – přidání, oprávnění, odebrání | 🧪 | |
| Proxy | ✅ | systémová nebo ruční v Nastavení |

## Zprávy

| Funkce | Stav | Pozn. |
|---|---|---|
| Přijaté, odeslané, stahování do sdílených databází | ✅ | |
| Podepsané ZFO, doručenky, události | ✅ | |
| Přečtení (lokálně, volitelně i v ISDS) | ✅ | |
| Automatické stahování, stahování po spuštění | ✅ | nastavení ⌘, |
| Ověření zprávy v ISDS | ✅ | uložené ZFO přes `AuthenticateMessage`; u VoDZ `AuthenticateBigMessage` 🧪; zastaralá `VerifyMessage` se už nevolá |
| Ověření souboru ZFO v ISDS | ✅ | `AuthenticateMessage`, u VoDZ `AuthenticateBigMessage` 🧪 |
| Lokální ověření podpisu a časového razítka | ✅ | ověřeno na vzorových i tvých zprávách |
| Autor zprávy | ✅ | `GetMessageAuthor2` |
| Smazání zprávy v ISDS | 🧪 | originál zůstane v archivu |
| Podezřelé zprávy (spam) | 🧪 | příznak `specMessFlag` v seznamu i detailu, nahlášení `SuspMessageReport` |
| Smazání zprávy jen v počítači | ✅ | jako originál, i s certifikáty |
| Stav vyřízení (nevyřízeno, vyřizuje se, vyřízeno) | ✅ | `process_state`, sdílený s originálem |
| Použít zprávu jako šablonu | ✅ | adresát, věc, č. j., přílohy |
| Doručenka a obálka do PDF, uložení ZFO zprávy i doručenky | ✅ | |
| Otevřít ZFO v jiné aplikaci, poslat e-mailem (ZFO, přílohy, obojí) | ✅ | |
| Stáhnout zprávu znovu z ISDS | 🧪 | stará kopie se nahradí až po stažení |
| Pozdější stav uložených zpráv (doručena, přečtena, v trezoru) | ✅ | jako originál: při stahování se porovná stav v seznamu, při změně se aktualizuje obálka a znovu stáhne doručenka s událostmi; ověřeno na odeslané zprávě 30. 10. 2026 |
| Hlídání expirace časových razítek | ✅ | Nástroje → Časová razítka, s obnovou; výsledky v `datovka-doplnky.db` |
| Seznam smazaných zpráv | ✅ | Informace o schránce, `GetListOfErasedMessages` |
| Velkoobjemové zprávy (VoDZ) | 🧪 | automaticky nad 20 MB; originál a přílohy v souborech vedle databáze jako původní Datovka |
| Databáze schránky v jiné složce (`database_dir`) | 🧪 | jako původní Datovka, i v záloze |
| Štítky (`tag.db`) | ✅ | |
| Lhůty | ✅ | nová funkce, sdílené |
| Integrovaný prohlížeč PDF | ✅ | |

## Odesílání

| Funkce | Stav | Pozn. |
|---|---|---|
| Nová zpráva, odpověď, přeposlání | ✅ | `CreateMessage`; ověřeno odpovědí finančnímu úřadu (k rukám, č. j.) 29. 10. 2026 |
| Přílohy včetně přetažení z plochy | ✅ | |
| Kontrola příloh před odesláním podle pravidel ISDS | ✅ | povolené formáty a MIME typy, nejvýš 100 příloh (10 ZIP/ASiC), 20 MB / 100 MB (VoDZ), název do 255 znaků, prázdné soubory, HTML bez skriptů, pravidla pro ZIP; `core/src/isds/rules.rs` |
| Více adresátů | 🧪 | `CreateMultipleMessage` (po 50); komu ISDS v ní zprávu nevytvoří (např. jen poštovní zprávou), tomu samostatně `CreateMessage`; VoDZ a poštovní typy po jednom |
| Poštovní datové zprávy (iniciační, odpověď, smluvní) | 🧪 | typy nabízí jen když je ISDS dovolí (`PDZSendInfo` Normal/Init) |
| Kontrola přístupnosti adresáta | ✅ | `CheckDataBox` po přidání adresáta, do nepřístupné schránky neodešle |
| K rukám, do vlastních rukou, fikce, zmocnění, zveřejnění identity | 🧪 | |
| Koncepty | ✅ | sdílené |
| Kontakty z korespondence | ✅ | automaticky, podle četnosti, v Adresáři i při psaní |
| Elektronická podání (10 služeb MV a SZR) | 🧪 | šablony shodné s originálem |

## Vyhledávání a adresáře

| Funkce | Stav | Pozn. |
|---|---|---|
| Hledání ve zprávách bez diakritiky | ✅ | |
| Pokročilé hledání (datum, nepřečtené, lhůta, štítek) | ✅ | |
| Adresář schránek – název, adresa, IČO, ID | ✅ | `ISDSSearch3` (dříve `ISDSSearch2`); v jádře i hledání podle IdOVM |
| Adresa schránky po složkách | ⬜ | `GetDataBoxAddress` zatím není potřeba, hledání vrací složenou adresu |
| Kredit, poštovní zprávy, datový trezor | ✅ | `DataBoxCreditInfo`, `PDZInfo`, `PDZSendInfo`, `DTInfo` |

## Archiv a soubory

| Funkce | Stav | Pozn. |
|---|---|---|
| Data původní Datovky, synchronizace přes iCloud, zámek zápisu | ✅ | |
| Import ZFO (přetažením i z menu) | ✅ | |
| Export ZFO zprávy a doručenky | ✅ | |
| Obálka do PDF, tisk | ✅ | |
| Přehled korespondence (CSV) | ✅ | |
| Odeslání e-mailem | ✅ | |
| Záloha a obnova | ✅ | |
| Import databází mobilní Datovky | ✅ | |
| Obnova časových razítek | 🧪 | `Re-signISDSDocument` |
| Spisová služba | 🧪 | REST jako originál |
| Příkazová řádka | ✅ | |

## Nad rámec původní aplikace

| Funkce | Stav | Pozn. |
|---|---|---|
| AI asistent: termíny z příloh, lhůta, kalendář (ICS) | 🧪 | Claude API nebo lokální Claude Code; na iPhonu API klíč a zápis přímo do Kalendáře |
| Zamykání aplikace biometrikou nebo kódem telefonu (iPhone, Android) | 🧪 | Nastavení → Zámek, jen v telefonu |
| Automatická aktualizace z vydání na GitHubu | ✅ | Mac a Windows vyzkoušené (1.0.1 → 1.0.2); Linux `.deb` 🧪; iPhone jen otevře stránku vydání |
| Procházení po letech a měsících | ✅ | strom ve složkách vlevo |

## Platformy

| Platforma | Stav |
|---|---|
| macOS | ✅ `DatovkaNG-macos.zip` z vydání, aktualizuje se sám |
| Windows | ✅ `DatovkaNG-windows-amd64.zip` z vydání, vyzkoušeno ve Windows 11, aktualizuje se sám |
| Linux | 🧪 `DatovkaNG-linux-amd64.deb` z vydání; v CI se sestaví a zabalí, na skutečném počítači zatím nevyzkoušeno |
| Linux (ostatní distribuce) | 🧪 `DatovkaNG-linux-x86_64.AppImage` a `aarch64`, aktualizuje se sám přepsáním souboru |
| iOS | 🧪 běží na iPhonu nad archivem z iCloud Drive; podepisuje se v Xcode, v App Store není |
| Android | 🧪 podepsané `DatovkaNG-android.apk` z vydání (arm64); archiv se přenáší zálohou ZIP, iCloud na Androidu není; aktualizace se stáhne a předá systémovému instalátoru |

## Chování

- Synchronizace na pozadí nikdy neotevírá okna a nekrade fokus.
- Interaktivní přihlášení (SMS, kód, mobilní klíč) se na pozadí nikdy samo
  nespouští a neposílá opakovaná upozornění. Schránka jen zobrazí tichý pruh
  s tlačítkem „Přihlásit“.
