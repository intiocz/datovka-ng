# Parita s původní Datovkou

Nová DATOVKA nesmí oproti původní (CZ.NIC, `reference/datovka-qt`) nic postrádat.
Seznam vychází z jejího zdrojového kódu.

Stav: ✅ hotovo · 🧪 hotovo, ale proti ISDS zatím neověřeno · ⬜ chybí

## Účty a přihlášení

| Funkce | Stav | Pozn. |
|---|---|---|
| Více schránek, přehledný seznam, změna pořadí | ✅ | pořadí v `dsgui.conf` |
| Přidání a odebrání schránky | ✅ | zápis do `dsgui.conf` |
| Jméno a heslo | ✅ | |
| Mobilní klíč | ✅ | jen na pokyn uživatele, bez opakovaných upozornění |
| Heslo + SMS kód | 🧪 | `type=totp` |
| Heslo + kód z aplikace (HOTP) | 🧪 | `type=hotp` |
| Certifikát, certifikát + heslo | 🧪 | PKCS#12, `ws1c` `certds/`/`hspis/`; ne na Androidu |
| Testovací prostředí | 🧪 | |
| Upozornění na konec platnosti hesla | 🧪 | |
| Změna hesla | 🧪 | uložené heslo se aktualizuje |
| Změna hesla v režimu OTP (SMS, kód z aplikace) | 🧪 | `ChangePasswordOTP`, `SendSMSCode` na `asws/changePassword` |
| Hesla šifrovaná PINem | ✅ | PBKDF2 + AES-256-CBC jako originál |
| Informace o vlastníkovi a uživateli | 🧪 | |
| Uživatelé schránky – výpis | 🧪 | |
| Uživatelé schránky – přidání, oprávnění, odebrání | 🧪 | |
| Proxy | ✅ | systémová nebo ruční v Nastavení |

## Zprávy

| Funkce | Stav | Pozn. |
|---|---|---|
| Přijaté, odeslané, stahování do sdílených databází | ✅ | |
| Podepsané ZFO, doručenky, události | ✅ | |
| Přečtení (lokálně, volitelně i v ISDS) | ✅ | |
| Automatické stahování, stahování po spuštění | ✅ | nastavení ⌘, |
| Ověření zprávy v ISDS | 🧪 | uložené ZFO přes `AuthenticateMessage` (VoDZ `AuthenticateBigMessage`); zastaralá `VerifyMessage` se už nevolá |
| Ověření souboru ZFO v ISDS | 🧪 | `AuthenticateMessage`, u VoDZ `AuthenticateBigMessage` |
| Lokální ověření podpisu a časového razítka | ✅ | ověřeno na vzorových i tvých zprávách |
| Autor zprávy | 🧪 | `GetMessageAuthor2` |
| Smazání zprávy v ISDS | 🧪 | originál zůstane v archivu |
| Smazání zprávy jen v počítači | ✅ | jako originál, i s certifikáty |
| Stav vyřízení (nevyřízeno, vyřizuje se, vyřízeno) | ✅ | `process_state`, sdílený s originálem |
| Použít zprávu jako šablonu | ✅ | adresát, věc, č. j., přílohy |
| Doručenka a obálka do PDF, uložení ZFO zprávy i doručenky | ✅ | |
| Otevřít ZFO v jiné aplikaci, poslat e-mailem (ZFO, přílohy, obojí) | ✅ | |
| Stáhnout zprávu znovu z ISDS | 🧪 | stará kopie se nahradí až po stažení |
| Seznam smazaných zpráv | 🧪 | Informace o schránce |
| Velkoobjemové zprávy (VoDZ) | 🧪 | automaticky nad 20 MB |
| Štítky (`tag.db`) | ✅ | |
| Lhůty | ✅ | nová funkce, sdílené |
| Integrovaný prohlížeč PDF | ✅ | |

## Odesílání

| Funkce | Stav | Pozn. |
|---|---|---|
| Nová zpráva, odpověď, přeposlání | 🧪 | `CreateMessage` |
| Přílohy včetně přetažení z plochy | ✅ | |
| Více adresátů | 🧪 | `CreateMultipleMessage` (po 50); komu ISDS v ní zprávu nevytvoří (např. jen poštovní zprávou), tomu samostatně `CreateMessage`; VoDZ a poštovní typy po jednom |
| Poštovní datové zprávy (iniciační, odpověď, smluvní) | 🧪 | typy nabízí jen když je ISDS dovolí (`PDZSendInfo` Normal/Init) |
| Kontrola přístupnosti adresáta | 🧪 | `CheckDataBox` po přidání adresáta, do nepřístupné schránky neodešle |
| K rukám, do vlastních rukou, fikce, zmocnění, zveřejnění identity | 🧪 | |
| Koncepty | ✅ | sdílené |
| Kontakty z korespondence | ✅ | automaticky, podle četnosti, v Adresáři i při psaní |
| Elektronická podání (10 služeb MV a SZR) | 🧪 | šablony shodné s originálem |

## Vyhledávání a adresáře

| Funkce | Stav | Pozn. |
|---|---|---|
| Hledání ve zprávách bez diakritiky | ✅ | |
| Pokročilé hledání (datum, nepřečtené, lhůta, štítek) | ✅ | |
| Adresář schránek – název, adresa, IČO, ID | 🧪 | `ISDSSearch3` (dříve `ISDSSearch2`); v jádře i hledání podle IdOVM |
| Adresa schránky po složkách | ⬜ | `GetDataBoxAddress` zatím není potřeba, hledání vrací složenou adresu |
| Kredit, poštovní zprávy, datový trezor | 🧪 | |

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
| Zamykání aplikace Face ID / kódem (iPhone) | 🧪 | Nastavení → Zámek |
| Procházení po letech a měsících | ✅ | strom ve složkách vlevo |

## Platformy

| Platforma | Stav |
|---|---|
| macOS | ✅ instalátor `dist/DatovkaNG.dmg` |
| Windows, Linux | ⬜ sestavení na dané platformě nebo v CI |
| iOS | 🧪 ověřeno v simulátoru nad skutečnými daty; na iPhone podepsat v Xcode |
| Android | 🧪 APK `dist/DATOVKA.apk` (arm64, x86_64); iCloud na Androidu není |

## Chování

- Synchronizace na pozadí nikdy neotevírá okna a nekrade fokus.
- Interaktivní přihlášení (SMS, kód, mobilní klíč) se na pozadí nikdy samo
  nespouští a neposílá opakovaná upozornění. Schránka jen zobrazí tichý pruh
  s tlačítkem „Přihlásit“.
