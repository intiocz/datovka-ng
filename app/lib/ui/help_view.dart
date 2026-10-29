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
            'archiv v Nastavení nepřesune do Dokumentů. Původní složka se přitom nesmaže.',
          ),
          const _H('Stahování a čtení'),
          const _P(
            'Tlačítko obnovit vlevo dole stáhne nové zprávy ze schránek, které se umějí '
            'přihlásit samy, tedy jménem a uloženým heslem. Přihlášení do schránky se '
            'v ISDS počítá jako doručení čekajících zpráv.',
          ),
          const _P(
            'Schránka s SMS, kódem nebo mobilním klíčem se na pozadí nikdy nepřihlašuje. '
            'Nad seznamem se jen objeví pruh Přihlásit.',
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
            'adresáta (7 znaků), věc a přílohy. První soubor je hlavní písemnost.',
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
            'novější verze. Na Macu se '
            'balíček vymění a stažený soubor se smaže. Na Linuxu se nainstaluje balíček '
            '.deb a taky se smaže. Na Windows 10 a novějším se složka s programem přepíše a zip '
            'se smaže. Na iPhonu se jen otevře stránka vydání, systém '
            'nedovolí aplikaci vyměnit samu sebe.',
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
