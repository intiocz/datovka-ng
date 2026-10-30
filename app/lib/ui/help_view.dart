import 'package:flutter/material.dart';

import '../data/updates.dart';

import '../theme.dart';
import 'connect_assistant.dart';

/// The user guide, in the app, in Czech.
Future<void> showHelp(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const HelpView()),
  );
}

class HelpView extends StatelessWidget {
  const HelpView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: t.paper,
      appBar: AppBar(
        title: const Text('Nápověda'),
        backgroundColor: t.paper,
        surfaceTintColor: t.paper,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 40),
        children: [
          Text('Datovka NG', style: text.headlineSmall),
          const SizedBox(height: 4),
          Text('Tahle sestava je alfa.', style: text.bodyMedium),
          const SizedBox(height: 8),
          const _P(
            'Klient datových schránek. Pracuje se stejnými zprávami jako původní '
            'Datovka od CZ.NIC. Do obchodů se zatím nedává. Nové verze se berou '
            'z balíčků na GitHubu intiocz/datovka-ng. Program se nesmí prodávat.',
          ),
          const _H('Archiv'),
          const _P(
            'Na Macu a na iPhonu je archiv jeden soubor Archiv.datovka. Ve Finderu '
            'a v Souborech se tváří jako jeden dokument. Když je zapnutý iCloud Drive, '
            'leží v jeho Dokumentech, takže ho vidí i druhý počítač a telefon.',
          ),
          const _P(
            'Číst jde na všech zařízeních naráz. Zapisovat smí v jednu chvíli jen jedno, '
            'aby se soubor v iCloudu nerozbil. Ostatní počkají a pak stáhnou totéž. '
            'Když aplikace spadne, zámek se po dvou minutách pustí sám.',
          ),
          const _P(
            'Kdo má ještě původní složku ~/.dsgui, tomu ji Datovka NG nechá, dokud '
            'archiv v Nastavení nepřesune do Dokumentů. Původní složka se přitom nesmaže. '
            'Na Windows a Linuxu je archiv v ~/.dsgui, na Androidu v úložišti aplikace '
            '(přenáší se zálohou).',
          ),
          const _P(
            'Datovka NG nic nepřevádí. Kdykoli se dá vrátit k původní Datovce od CZ.NIC '
            'a ta uvidí všechny zprávy včetně příloh a originálů. Jen obě aplikace '
            'nespouštějte naráz nad stejným archivem.',
          ),
          const _P(
            'Na počítači jde v Nastavení → Archiv zapnout automatické zálohy do zvolené '
            'složky, denně nebo týdně, s počtem záloh, které se ponechají.',
          ),
          const _H('Stahování a čtení'),
          const _P(
            'Tlačítko obnovit vlevo dole stáhne nové zprávy ze schránek, které se umějí '
            'přihlásit samy, tedy jménem a uloženým heslem. Stažení seznamu přijatých '
            'zpráv ISDS počítá jako přihlášení do schránky, tedy jako doručení '
            'čekajících zpráv. Stažení odeslaných zpráv nic nedoručí.',
          ),
          const _P(
            'Automatické stahování je ve výchozím stavu ruční: zprávy se stáhnou po '
            'spuštění a tlačítkem. Interval si zvolíte v Nastavení → Stahování.',
          ),
          const _P(
            'Schránka s SMS, kódem nebo mobilním klíčem se na pozadí nikdy nepřihlašuje. '
            'Nad seznamem se jen objeví pruh Přihlásit. Jednou přihlášenou schránku '
            'Datovka každých 25 minut udrží, nic tím nedoručí.',
          ),
          const _P(
            'Odeslanou zprávu ISDS obvykle do několika vteřin dodá adresátovi, teprve '
            'pak se dá stáhnout. Datovka se po odeslání několikrát podívá znovu, takže '
            'zpráva bývá v Odeslaných do minuty. Vypnout jde v Nastavení → Stahování. '
            'Když ji adresát převezme, Datovka to při stahování zjistí a doplní čas '
            'doručení.',
          ),
          const _P(
            'Zprávu, kterou ISDS označí jako podezřelou (spam), Datovka označí v seznamu '
            'i v detailu. Přijatou zprávu jde nahlásit v menu zprávy → ISDS.',
          ),
          const _P(
            'Pravým tlačítkem na schránku (na telefonu podržením) ji přejmenujete, '
            'přihlásíte nebo odeberete. Odebraná schránka zmizí ze seznamu, archiv '
            'jejích zpráv zůstane.',
          ),
          const _P(
            'Otevřením se zpráva označí jako přečtená. Podepsaný originál (ZFO) uložíte '
            'ikonou stažení. To je doklad pro úřad. Hledání je bez diakritiky, ⌘F '
            'skočí do pole. Šipky posouvají výběr, ⌘-klik a Shift-klik vyberou víc zpráv.',
          ),
          const _P(
            'Šipka před složkou vlevo rozbalí roky, šipka před rokem měsíce. '
            'Kliknutím na rok nebo měsíc se zobrazí jen jeho zprávy.',
          ),
          const _H('Psaní'),
          const _P(
            'Napsat zprávu, Odpovědět, nebo schránka z adresáře. Vyplňte ID schránky '
            'adresáta (7 znaků), věc a přílohy. První soubor je hlavní písemnost. '
            'Přílohy se hned kontrolují podle pravidel ISDS (formáty, počet, velikost); '
            'co by ISDS odmítl, se ukáže pod seznamem a zprávu nepustí.',
          ),
          const _H('Asistent'),
          const _P(
            'U příloh je Najít termíny. Než se něco pošle, uvidíte co se čte. '
            'Text příloh může opustit tento počítač. Najednou je připojený jen jeden '
            'způsob: model v počítači (Ollama nebo LM Studio), API klíč (Claude nebo '
            'OpenAI), předplatné přes Claude Code, jiná aplikace přes MCP, nebo žádný '
            'asistent a jen ruční lhůty. V telefonu jde jen API klíč.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => showConnectAssistant(context),
              child: const Text('Připojit asistenta'),
            ),
          ),
          const _H('Aktualizace'),
          const _P(
            'Aplikace se při startu podívá na vydání intiocz/datovka-ng, jestli není '
            'novější verze, a nabídne ji se seznamem změn. Ručně to zkontrolujete '
            'kliknutím na číslo verze dole. Na Macu se balíček vymění a stažený soubor '
            'se smaže. Na Linuxu se nainstaluje balíček .deb (pro Intel, nebo ARM podle '
            'počítače) a systém se zeptá na heslo správce. Na Windows 10 a novějším se '
            'složka s programem přepíše a zip se smaže. AppImage se přepíše novou '
            'verzí. Na Androidu se balíček stáhne a systém požádá o potvrzení '
            'instalace. Na iPhonu se jen otevře stránka vydání.',
          ),
          const _H('Kdo to platí'),
          const _P(
            'Vývoj Datovky NG platí projekt NENDE.cz. NENDE hlídá veřejné zakázky '
            'a upozorňuje na ty, které se vás týkají.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => openLink(nendeLink('help')),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('nende.cz'),
            ),
          ),
          const _H('Bez záruky'),
          const _P(
            'Datovka NG se dává tak, jak je. Za nic neručíme. Nezaručujeme, že poběží '
            'bez chyb, že zprávu doručí, že lhůtu přečte správně, ani že se hodí '
            'k tomu, na co ji použijete.',
          ),
          const _P(
            'V rozsahu, v jakém to právo dovoluje, neneseme odpovědnost za škodu '
            'z používání programu. Rozhodnutí podle datové zprávy si ověřte v originálu. '
            'Závazné je anglické znění licence PolyForm Noncommercial 1.0.0.',
          ),
        ],
      ),
    );
  }
}

class _H extends StatelessWidget {
  final String text;
  const _H(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 6),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _P extends StatelessWidget {
  final String text;
  const _P(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
