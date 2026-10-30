// Every dialog opened on a phone-sized screen: nothing may overflow, and
// rows of labels and values must leave the values room.
import '../dev/demo_data.dart';

import 'package:datovka/data/app_state.dart';
import 'package:datovka/data/updates.dart';
import 'package:datovka/main.dart';
import 'package:datovka/ui/ai_dialog.dart';
import 'package:datovka/ui/box_info.dart';
import 'package:datovka/ui/compose.dart';
import 'package:datovka/ui/connect_assistant.dart';
import 'package:datovka/ui/gov_services_dialog.dart';
import 'package:datovka/ui/help_view.dart';
import 'package:datovka/ui/info_view.dart';
import 'package:datovka/ui/login_dialog.dart';
import 'package:datovka/ui/records_dialog.dart';
import 'package:datovka/ui/search_filter.dart';
import 'package:datovka/ui/settings_dialog.dart';
import 'package:datovka/ui/signature_view.dart';
import 'package:datovka/ui/stamps_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => checkUpdatesOnStart = false);

  final dialogs = <String, void Function(BuildContext, AppState)>{
    'nastavení': (c, s) => showSettings(c, s),
    'nová schránka': (c, s) => showAddBoxDialog(c),
    'přihlášení': (c, s) => showLoginDialog(c, s.boxes.first),
    'způsob přihlášení': (c, s) => showChangeLoginDialog(c, s.boxes.first),
    'informace o schránce': (c, s) => showBoxInfo(c, s.boxes.first),
    'psaní zprávy': (c, s) => showCompose(c),
    'elektronická podání': (c, s) => showGovServices(c),
    'časová razítka': (c, s) => showStamps(c),
    'spisová služba': (c, s) => showRecordsSettings(c),
    'hledání': (c, s) => showSearchFilter(c),
    'asistent': (c, s) => showConnectAssistant(c),
    'rozbor příloh': (c, s) => showAiAnalysis(c, s.visible.first),
    'nápověda': (c, s) => showHelp(c),
    'podpis': (c, s) => showSignatureReport(c, {
      'signature_valid': true,
      'signer': {'common_name': 'Informační systém datových schránek'},
      'chain': ['ISDS', 'PostSignum Qualified CA 5', 'PostSignum Root QCA 4'],
      'dm_hash': {'matches_content': true},
      'timestamp': {
        'gen_time': '2026-10-29T19:59:16Z',
        'signature_valid': true,
        'imprint_matches': true,
      },
      'problems': <String>[],
    }),
    'údaje z ISDS': (c, s) => showInfoDialog(
      c,
      'Vlastník schránky',
      () async => {
        'dbOwnerInfoExt2': {
          'maItem': [
            {
              'key': 'firmName',
              'value': 'Velmi dlouhý název společnosti s ručením omezeným',
            },
            {
              'key': 'fullAddress',
              'value': 'Nové sady 988/2, Staré Brno, 602 00 Brno',
            },
            {'key': 'dbOpenAddressing', 'value': 'true'},
          ],
        },
      },
    ),
  };

  for (final width in [390.0, 360.0]) {
    for (final MapEntry(key: name, value: open) in dialogs.entries) {
      testWidgets('$name se vejde na telefon (${width.toInt()})', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState(
          initialBoxes: demoBoxes,
          messages: demoMessages(),
        );
        await tester.pumpWidget(DatovkaApp(state: state));
        open(tester.element(find.byType(Scaffold).first), state);
        await tester.pump();
        // Some dialogs load with real I/O (e.g. looking for Claude Code in
        // the shell), slower on CI: let it finish before settling, since a
        // spinner never settles.
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('všechny stránky nastavení se vejdou na malý telefon', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(initialBoxes: demoBoxes, messages: demoMessages());
    await tester.pumpWidget(DatovkaApp(state: state));
    showSettings(tester.element(find.byType(Scaffold).first), state);
    await tester.pumpAndSettle();
    for (final page in [
      'Zobrazení',
      'Zámek',
      'Síť',
      'Archiv',
      'Asistent',
      'Aktualizace',
      'Stahování',
    ]) {
      final tab = find.text(page);
      if (tab.evaluate().isEmpty) continue;
      await tester.ensureVisible(tab.first);
      await tester.tap(tab.first);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('elektronická podání: na telefonu seznam, formulář a zpět', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(initialBoxes: demoBoxes, messages: demoMessages());
    await tester.pumpWidget(DatovkaApp(state: state));
    showGovServices(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    final services = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(ListTile),
    );
    expect(services, findsWidgets);
    await tester.tap(services.first);
    await tester.pumpAndSettle();
    expect(find.text('Odeslat žádost'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.byTooltip('Zpět na seznam'));
    await tester.pumpAndSettle();
    expect(services, findsWidgets);
  });

  testWidgets('údaje z ISDS mají na telefonu popisek nad hodnotou', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: InfoView(
            data: {
              'maItem': [
                {'key': 'userType', 'value': 'VIRTUAL'},
              ],
            },
          ),
        ),
      ),
    );
    expect(find.text('maItem'), findsNothing);
    expect(find.text('key'), findsNothing);
    final label = tester.getTopLeft(find.text('Role uživatele'));
    final value = tester.getTopLeft(find.text('Spisová služba'));
    expect(value.dy, greaterThan(label.dy), reason: 'hodnota je pod popiskem');
  });
}
