# Datovka NG – uživatelská příručka

Datovka NG je klient datových schránek (ISDS) pro macOS, Windows 10 a novější, Ubuntu, Debian, Mint
a iPhone. Pracuje se stejnými daty jako původní Datovka od CZ.NIC, takže po
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

## Stahování zpráv

Tlačítko obnovit vlevo dole stáhne nové přijaté a odeslané zprávy ze všech
schránek, které se umějí přihlásit bez vás, tedy jménem a uloženým heslem.
Ke každé zprávě se uloží i podepsaný originál a doručenka.

> Přihlášení do schránky se v ISDS počítá jako doručení čekajících zpráv
> (doručení přihlášením). Platí to stejně jako u původní Datovky nebo webu.

Schránky s přihlášením přes SMS, kód z aplikace nebo mobilní klíč se na pozadí
nikdy nepřihlašují. Když jim vyprší přihlášení, objeví se nad seznamem tichý
pruh s tlačítkem *Přihlásit*. Aplikace sama neotevírá okna, nebere fokus
a neposílá opakovaná upozornění.

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
6. Klikněte na *Odeslat*. Po odeslání se zobrazí ID nové zprávy a zpráva se
   stáhne do Odeslaných.

U odpovědi se automaticky vyplní adresát, věc s předponou „Re:“ a prohozená
čísla jednací.

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
  v jiné aplikaci; poslat e-mailem; ISDS (ověřit, kdo odeslal, doručenka
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
- **Schránky**: pravým tlačítkem na schránku – informace o schránce (vlastník,
  uživatelé, kredit, datový trezor, heslo a jeho změna), přihlásit/odhlásit,
  posunout, odebrat. Pořadí změníte i přetažením.
- **Nástroje** (⋮ vlevo dole): ověřit soubor ZFO, importovat ZFO (nebo je
  přetáhněte do okna), přehled korespondence do CSV, záloha a obnova,
  AI asistent, nastavení.
- **Nastavení** (⌘,): jak často stahovat, stahování po spuštění, označování
  přečtení v ISDS.

## Další nástroje

- **Elektronická podání** (Nástroje): výpis z rejstříku trestů, insolvenčního,
  obchodního a živnostenského rejstříku, bodového hodnocení řidiče, registru
  obyvatel a osob. Vyberete schránku, vyplníte údaje a žádost se odešle úřadu.
- **Spisová služba** (Nástroje): adresa a token vaší spisové služby. Zprávu pak
  uložíte do spisu z menu zprávy *Uložit do spisové služby…*.
- **Import z mobilní Datovky** (Nástroje): vyberte složku s rozbaleným exportem
  z mobilní aplikace.
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

- **macOS**: otevřete `DatovkaNG.dmg` a přetáhněte Datovku NG do Aplikací. Aplikace
  není podepsaná certifikátem Apple; při prvním spuštění na jiném Macu ji
  otevřete pravým tlačítkem → Otevřít.
- **iPhone/iPad**: sestavení přes `scripts/build-ios.sh`; k instalaci je potřeba
  podepsat ji v Xcode vlastním Apple ID. Při prvním spuštění vyberete
  v Souborech složku iCloud Drive → Datovka archiv (stejnou jako na Macu). Pak se
  otevírá sama a zprávy se stahují stejně jako na počítači. Přílohy se otevírají
  v náhledu, odkud je sdílíte nebo uložíte. V Nastavení → Zámek lze zapnout
  zamykání přes Face ID nebo kód telefonu, při spuštění a po návratu do aplikace.
- **Android, Windows, Linux**: viz `docs/vyvoj.md`. Na Androidu není iCloud,
  složku s daty je potřeba synchronizovat jinak (např. Syncthing, Nextcloud).

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
| *heslo je chráněné PINem* | Zadávání PINu zatím není hotové. |
| *způsob přihlášení … vyžaduje přihlášení v aplikaci* | Schránka s SMS, kódem nebo mobilním klíčem. Interaktivní přihlášení zatím není napojené na ISDS. |
| *ISDS chyba …* | Text chyby pochází přímo z ISDS (např. neplatný adresát nebo nepovolený formát přílohy). |

## Bez záruky

Datovka NG se dává tak, jak je. Za nic neručíme. Nezaručujeme, že poběží bez chyb, že zprávu doručí, že lhůtu přečte správně, ani že se hodí k tomu, na co ji použijete. V rozsahu, v jakém to právo dovoluje, neneseme odpovědnost za škodu z používání programu. Rozhodnutí podle datové zprávy si ověřte v originálu. Závazné je anglické znění licence PolyForm Noncommercial 1.0.0.
