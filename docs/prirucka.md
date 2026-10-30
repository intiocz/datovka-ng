# Datovka NG – uživatelská příručka

Datovka NG je klient datových schránek (ISDS) pro macOS, Windows 10 a novější,
Linux (Ubuntu, Debian, Mint; Intel i ARM), iPhone a Android. Pracuje se stejnými daty jako původní Datovka od CZ.NIC, takže po
spuštění vidíte své schránky, uložená hesla a historii zpráv. Do obchodů se
zatím nedává. Nové verze se berou z balíčků na GitHubu.

## Kde jsou data

Na Macu a na iPhonu je archiv jeden soubor `Archiv.datovka`. Když je zapnutý
iCloud Drive, leží v Dokumentech na iCloudu a sdílí se mezi Apple zařízeními.
Kdo má ještě původní složku `~/.dsgui`, tomu ji aplikace nechá, dokud archiv
v Nastavení nezkopíruje do Dokumentů. Uvnitř souboru jsou pořád stejné databáze:

| Soubor | Obsah |
|---|---|
| `dsgui.conf` | seznam schránek, přihlašovací údaje |
| `messages.shelf.db` | údaje o schránkách (ID, vlastník) |
| `{uživatel}_{rok}___0.db` | zprávy daného roku včetně podepsaných originálů (ZFO) |
| `.datovka-zamek.json` | zámek: které zařízení právě zapisuje |

Na Windows a Linuxu je archiv ve složce `.dsgui` v domovské složce, stejně
jako u původní Datovky. Na Androidu je v úložišti aplikace a přenáší se
zálohou (Nástroje → Záloha / Obnovit ze zálohy).

Ve Finderu nastavte u složky `Datovka` v iCloud Drive „Ponechat staženo“, aby ji
systém neuvolnil z disku.

Archiv jde číst na telefonu i na několika počítačích najednou. Zapisovat
(stahovat, označovat přečtení, odesílat) smí v jednu chvíli jen jedno zařízení,
aby se databáze v iCloudu nerozbily. Ostatní počkají a pak stáhnou totéž.
Zámek se po zápisu hned pustí. Když zařízení spadne, další zápis ho po dvou
minutách převezme sám.

## Okno aplikace

- **Vlevo**: tlačítko *Napsat zprávu*, složky (Přijaté, Odeslané, Lhůty,
  Všechny zprávy, Adresář schránek) a seznam schránek. U schránky je počet
  nepřečtených zpráv. Klíček znamená, že schránka čeká na přihlášení.
- **Uprostřed**: seznam zpráv s vyhledáváním. Hledá se ve věci, odesílateli
  a číslech jednacích, na diakritice nezáleží.
- **Vpravo**: detail zprávy, tedy odesílatel, adresát, stav originálu, lhůta,
  přílohy a údaje zprávy.

Na úzkém okně a na telefonu se složky schovají do menu a detail se otevře přes
celou obrazovku.

## Návrat k původní Datovce

Datovka NG nic nepřevádí, pracuje přímo nad archivem původní Datovky. Když
vám nebude vyhovovat, zavřete ji a otevřete původní Datovku od CZ.NIC: uvidí
všechny zprávy, i ty stažené a odeslané v Datovce NG, včetně příloh,
podepsaných originálů, doručenek, štítků, poznámek a stavu vyřízení.

- Obě aplikace nespouštějte najednou nad stejným archivem. Původní Datovka
  nezná zámek zápisu Datovky NG.
- Lhůty a koncepty z Datovky NG původní Datovka nezná. Zůstanou v souboru
  `datovka-doplnky.db` a po návratu do Datovky NG je najdete zase.
- Heslo, které jste zadali nebo změnili v Datovce NG, je jen v Klíčence
  (Správci pověření, klíčence Linuxu). Původní Datovka se na něj jednou zeptá.
- Na Macu, kde jste v Nastavení zkopírovali archiv do Dokumentů
  (`Archiv.datovka`), čte původní Datovka dál starou složku `~/.dsgui`.
  Zprávy stažené po kopírování jsou jen v `Archiv.datovka`. Obsah balíčku
  (pravým tlačítkem → Zobrazit obsah balíčku) zkopírujte zpět do `~/.dsgui`,
  nebo spusťte původní Datovku s `--conf-dir` a cestou k balíčku.

## Stahování zpráv

Tlačítko obnovit vlevo dole stáhne nové přijaté a odeslané zprávy ze všech
schránek, které se umějí přihlásit bez vás, tedy jménem a uloženým heslem.
Ke každé zprávě se uloží i podepsaný originál a doručenka.

Nové zprávy se stáhnou po spuštění aplikace a pak tlačítkem. Provozní řád
ISDS chce, aby se aplikace v počítači přihlašovala na pokyn uživatele, proto
je automatické stahování ve výchozím stavu ruční. V Nastavení → Stahování si
můžete zvolit interval (5 minut až 4 hodiny), je to vaše rozhodnutí.

Zprávu, kterou ISDS označí jako podezřelou (spam, možný škodlivý obsah),
Datovka označí v seznamu i v detailu. Podezřelou přijatou zprávu můžete sami
nahlásit správci ISDS: menu zprávy → ISDS → *Nahlásit jako podezřelou
(spam)…*. Zprávy od úřadů nahlásit nejde.

> Stažení seznamu přijatých zpráv ISDS počítá jako přihlášení do schránky,
> tedy jako doručení čekajících zpráv (doručení přihlášením). Platí to stejně
> jako u původní Datovky nebo webu. Stažení odeslaných zpráv, ověření zprávy
> ani hledání v adresáři nic nedoručí (Provozní řád ISDS, 26. 6. 2026).

Schránky s přihlášením přes SMS, kód z aplikace nebo mobilní klíč se na pozadí
nikdy nepřihlašují. Když jim vyprší přihlášení, objeví se nad seznamem tichý
pruh s tlačítkem *Přihlásit*. Aplikace sama neotevírá okna, nebere fokus
a neposílá opakovaná upozornění.

Jednou přihlášená schránka zůstane přihlášená, dokud Datovka běží: ISDS
přihlášení ukončí po 30 minutách bez požadavku, a tak se Datovka každých
25 minut krátce ozve (stejně jako původní Datovka). Tenhle požadavek nic
nedoručí. Vypnout jde v Nastavení → Stahování (*Udržovat přihlášení*).
Telefon na pozadí se neozývá; po návratu do aplikace se hned ověří, jestli
přihlášení ještě platí.

Zprávu odeslanou z Datovky ISDS obvykle během několika vteřin dodá do
schránky adresáta. Teprve pak se dá stáhnout. Datovka se proto po odeslání
několikrát krátce po sobě podívá do ISDS a zprávu stáhne do Odeslaných,
obvykle do minuty. Vypnout jde v Nastavení → Stahování (*Odeslanou zprávu
stáhnout hned*), zpráva pak přijde s dalším stahováním.

## Čtení zprávy

- Otevřením se zpráva označí jako přečtená, stejně jako v původní Datovce.
  Ikonou obálky v liště ji můžete označit zase jako nepřečtenou.
  otevírá.
- **Uložit podepsanou zprávu (ZFO)**: ikona stažení v liště. Originál ZFO je
  právně platný doklad, který lze předložit úřadu nebo soudu.
- **Lhůta**: u zprávy můžete nastavit lhůtu (8, 15, 30 dní nebo vlastní datum).
  Zobrazí se ukazatel v seznamu a zpráva se objeví ve složce Lhůty. Barva se mění
  podle toho, kolik času zbývá. *Lhůty se zatím neukládají, po zavření
  aplikace zmizí.*

## Psaní zprávy

1. Klikněte na *Napsat zprávu*, na *Odpovědět* u přijaté zprávy, nebo na
   *Napsat zprávu* u schránky nalezené v adresáři.
2. Vyberte schránku, ze které zprávu odesíláte (*Od*).
3. Vyplňte **ID schránky adresáta** (7 znaků), nebo adresáta najděte podle
   názvu či IČO v poli vedle a vyberte ho ze seznamu.
4. Vyplňte **věc**, případně čísla jednací, *K rukám* a *Do vlastních rukou*.
5. Přidejte dokumenty: přetáhněte je do okna z plochy, Finderu nebo jiné
   aplikace, nebo použijte *Přidat soubory*. První je hlavní písemnost, další
   jsou přílohy.
6. Klikněte na *Odeslat*. Po odeslání se zobrazí ID nové zprávy. Do
   Odeslaných se zpráva stáhne, jakmile ji ISDS dodá (viz Stahování zpráv).

U odpovědi se automaticky vyplní adresát, věc s předponou „Re:“ a prohozená
čísla jednací.

Po přidání adresáta se aplikace ISDS zeptá, jestli jeho schránka může
přijímat zprávy. Nepřístupnou schránku (znepřístupněnou, zrušenou) označí
a zprávu do ní neodešle. Typy poštovní zprávy v *Dalších volbách* nabízí,
jen když je ISDS z vaší schránky danému adresátovi dovolí.

Běžná zpráva více adresátům se odešle najednou, každý adresát dostane svou
zprávu se svým ID. Komu ISDS takovou zprávu nevezme (např. adresátovi, kterému
lze psát jen poštovní zprávou), tomu se zpráva pošle samostatně.

## Adresář schránek

Nahoře jsou *Moje kontakty*: všichni, se kterými máte přijaté nebo odeslané
zprávy, seřazení podle toho, jak často si píšete. Seznam se skládá sám ze
zpráv, nic se neudržuje ručně. Při psaní do vyhledávání se filtrují i kontakty.

Složka *Adresář schránek* prohledává veřejný seznam všech datových schránek
přímo v ISDS:

- **Název nebo adresa**: fulltextové hledání, např. „finanční úřad Brno“,
- **IČO**: osmimístné IČO,
- **ID schránky**: sedmiznakové ID.

Zaškrtnutím *Jen orgány veřejné moci* omezíte výsledky na úřady. Ikonou kopírování
vložíte ID schránky do schránky systému, tlačítko *Napsat zprávu* otevře
novou zprávu pro daného adresáta. Hledání se přihlašuje vybranou schránkou,
případně první schránkou s uloženým heslem.

## Další funkce

- **Akce u zprávy** (pravé tlačítko na zprávě v seznamu nebo ikona ⋯ v liště):
  odpovědět, přeposlat, použít jako šablonu; Označit (přečtené, nevyřízeno,
  vyřizuje se, vyřízeno); lhůta, štítek, poznámka; Uložit (ZFO zprávy
  i doručenky, obálka a doručenka do PDF, všechny přílohy); otevřít ZFO
  v jiné aplikaci; poslat e-mailem; ISDS (ověřit, tedy ISDS posoudí celý uložený originál ZFO; kdo odeslal, doručenka
  a události, obnovit razítko, stáhnout znovu); smazat jen v počítači nebo
  v ISDS. Smazání v ISDS nechá podepsaný originál v archivu, smazání
  v počítači ho odstraní, ale do vymazání v ISDS jde zprávu stáhnout znovu.
- **Obálka do PDF / tisk**: ikona tiskárny v liště zprávy.
- **Štítky**: v detailu zprávy, sdílené s původní Datovkou (`tag.db`).
- **Roky a měsíce**: šipka před složkou Přijaté, Odeslané nebo Všechny zprávy
  v levém panelu rozbalí roky s počty zpráv, šipka před rokem jeho měsíce.
  Šipka jen rozbaluje, kliknutím na rok nebo měsíc se zprávy zobrazí. Zvolené
  období je nad seznamem, křížkem se vrátíte k celé složce.
- **Pokročilé hledání**: ikona filtru vedle vyhledávání (datum, nepřečtené,
  se lhůtou, štítek).
- **Koncepty**: složka Koncepty; rozepsanou zprávu uložíte tlačítkem *Uložit koncept*.
- **Schránky**: pravým tlačítkem na schránku (na telefonu podržením) –
  informace o schránce (vlastník, uživatelé, kredit, datový trezor, heslo
  a jeho změna), přejmenovat, způsob přihlášení, přihlásit/odhlásit, napsat
  zprávu, *Odebrat schránku…*. Odebraná schránka zmizí ze seznamu a její
  uložené heslo se smaže, archiv zpráv zůstane. Pořadí na počítači změníte
  přetažením, na telefonu jsou schránky podle abecedy. Schránka s přihlášením přes
  SMS nebo bezpečnostní kód potřebuje ke změně hesla i kód: tlačítko
  *Poslat SMS* si ho vyžádá (zadejte nejdřív současné heslo).
- **Nástroje** (⋮ vlevo dole): ověřit soubor ZFO, importovat ZFO (nebo je
  přetáhněte do okna), přehled korespondence do CSV, záloha a obnova,
  AI asistent, nastavení.
- **Nastavení** (⌘,): jak často stahovat, stahování po spuštění, stažení
  odeslané zprávy hned po dodání, označování přečtení v ISDS, zobrazení
  (velikost písma o kousek menší nebo větší, světlý nebo tmavý vzhled),
  síť (proxy), archiv, asistent, aktualizace. Na telefonu také zámek.

## Automatické zálohy

Na počítači v Nastavení → Archiv zvolíte složku pro zálohy, ideálně na jiném
disku nebo síťovém úložišti, a jak často zálohovat (denně nebo týdně).
Datovka pak sama uloží celý archiv jako jeden soubor
`Datovka-zaloha-RRRR-MM-DD-HHMM.zip` a ponechá jen zvolený počet
nejnovějších záloh (3 až 30). Jiné soubory ve složce nemaže. Tlačítkem
*Zálohovat teď* zálohu uděláte hned. Obnova je v Nástrojích → Obnovit ze
zálohy.

Záloha obsahuje i hesla, která má původní Datovka uložená v `dsgui.conf`.
Ukládejte ji tam, kam se nedostane nikdo cizí.

## Další nástroje

- **Elektronická podání** (Nástroje): výpis z rejstříku trestů, insolvenčního,
  obchodního a živnostenského rejstříku, bodového hodnocení řidiče, registru
  obyvatel a osob. Vyberete schránku, vyplníte údaje a žádost se odešle úřadu.
- **Spisová služba** (Nástroje): adresa a token vaší spisové služby. Zprávu pak
  uložíte do spisu z menu zprávy *Uložit do spisové služby…*.
- **Import z mobilní Datovky** (Nástroje): vyberte složku s rozbaleným exportem
  z mobilní aplikace.
- **Časová razítka** (Nástroje): zprávy, kterým brzy vyprší časové razítko,
  a tím možnost prokázat originál. ISDS razítko obnoví v posledním roce
  a půl jeho platnosti, tlačítkem Obnovit u zprávy.
- **Podpis a časové razítko**: klikněte na zelený rámeček v detailu zprávy.
  DATOVKA ověří podpis, certifikáty i časové razítko přímo v počítači.
  *Obnovit časové razítko* v menu zprávy nechá ISDS originál znovu orazítkovat.
- **Uživatelé schránky** (Informace o schránce): přidání pověřené osoby,
  změna oprávnění, odebrání.
- **PIN**: pokud máte hesla v původní Datovce chráněná PINem, nahoře se objeví
  *Zadat PIN*. PIN se nikam neukládá, platí do zavření aplikace.
- **Certifikát**: u schránky s přihlášením certifikátem zadáte při přihlášení
  heslo k certifikátu (soubor .p12/.pfx z nastavení schránky, nebo ho vyberete).
- **Velkoobjemové zprávy**: zprávy nad 20 MB se odešlou a stáhnou automaticky
  jako velkoobjemové.

## Instalace

Balíčky jsou u [vydání na GitHubu](https://github.com/intiocz/datovka-ng/releases/latest).

- **macOS**: `DatovkaNG-macos.zip` rozbalte a Datovku NG přetáhněte do
  Aplikací. Aplikace není podepsaná certifikátem Apple, poprvé ji otevřete
  pravým tlačítkem → Otevřít.
- **Windows 10 a 11**: `DatovkaNG-windows-amd64.zip` rozbalte a spusťte
  `datovka-ng.exe`.
- **Linux**: `sudo apt install ./DatovkaNG-linux-amd64.deb`, na počítači
  s procesorem ARM `DatovkaNG-linux-arm64.deb`. Hesla jdou do systémové
  klíčenky. Kdo se přihlašuje automaticky, nemá ji ještě založenou: při prvním
  uložení hesla se systém zeptá na heslo k nové klíčence.
- **Android**: `DatovkaNG-android.apk` otevřete v telefonu a povolte instalaci.
  Na Androidu není iCloud, archiv se přenáší zálohou ZIP (Nástroje → Záloha
  na počítači, Obnovit ze zálohy v telefonu).
- **iPhone/iPad**: v App Store není, sestavuje se přes `scripts/build-ios.sh`
  a podepisuje v Xcode vlastním Apple ID. Při prvním spuštění vyberete
  v Souborech složku iCloud Drive → Datovka archiv (stejnou jako na Macu).
  Přílohy se otevírají v náhledu, odkud je sdílíte nebo uložíte.

Na telefonu lze v Nastavení → Zámek zapnout zamykání přes Face ID, otisk
prstu nebo kód telefonu, při spuštění a po návratu do aplikace.

Na Macu, Windows a Linuxu se aplikace při startu podívá, jestli není novější
verze, a nabídne ji i se seznamem změn. Po potvrzení se sama nainstaluje.
Ručně to zkontrolujete kliknutím na číslo verze ve stavovém řádku.

## AI asistent

U příloh zprávy je tlačítko *Najít termíny (AI)*. Asistent přečte přílohy,
napíše shrnutí, navrhne lhůtu a najde termíny (lhůty, platby, jednání). Vybrané
termíny přidáte do kalendáře (na počítači se otevře import do Kalendáře,
na iPhonu se zapíšou rovnou) nebo na počítači uložíte jako `.ics`. Lhůty
a platby jdou do kalendáře o den dřív. Navrženou lhůtu můžete nastavit
jako lhůtu zprávy.

Před rozborem se ukáže, co se čte. Text příloh může opustit tento počítač.
API klíč je v Klíčence (na Windows ve Správci pověření, na Linuxu
v úložišti hesel), nikdy v archivu. Termíny vždy ověřte v dokumentu.

Na iPhonu jde asistent připojit jen přes API klíč (Claude nebo OpenAI).
Model v počítači ani Claude Code v telefonu běžet nemohou.

## Řešení potíží

| Hláška | Co dělat |
|---|---|
| *zařízení X právě zapisuje* | Čtení funguje. Chvíli počkejte a zvolte Znovu. Když je to zařízení vypnuté, zvolte Převzít. |
| *přihlášení vypršelo* | Schránka s SMS, kódem nebo mobilním klíčem. Klikněte na *Přihlásit* v pruhu nad seznamem. |
| *heslo se neuložilo: systém se ptal na heslo k nové klíčence* | Linux: uložte heslo znovu a v systémovém okně zvolte heslo klíčence. |
| *nepodařilo se spojit se serverem*, *spojení se serverem se přerušilo* | Datovka zkouší spojení znovu sama. Pokud hláška trvá, zkontrolujte připojení nebo proxy v Nastavení → Síť. |
| *ISDS chyba …* | Text chyby pochází přímo z ISDS (např. neplatný adresát nebo nepovolený formát přílohy). |

## Bez záruky

Datovka NG se dává tak, jak je. Za nic neručíme. Nezaručujeme, že poběží bez chyb, že zprávu doručí, že lhůtu přečte správně, ani že se hodí k tomu, na co ji použijete. V rozsahu, v jakém to právo dovoluje, neneseme odpovědnost za škodu z používání programu. Rozhodnutí podle datové zprávy si ověřte v originálu. Závazné je anglické znění licence PolyForm Noncommercial 1.0.0.
