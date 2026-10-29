import 'package:datovka/data/core_bridge_ffi.dart' show argsWithDataDir;
import 'package:datovka/data/ai.dart';
import 'package:datovka/data/mailbox.dart';
import 'package:datovka/data/models.dart';
import 'package:datovka/data/archive_location.dart';
import 'package:datovka/data/settings.dart';
import 'package:datovka/data/updates.dart';
import 'package:datovka/data/user_error.dart';
import 'package:datovka/main.dart';
import 'package:datovka/ui/ai_dialog.dart';
import 'package:datovka/ui/app_lock.dart';
import 'package:datovka/ui/home.dart';
import 'package:datovka/ui/login_dialog.dart';
import 'package:datovka/ui/format.dart' show monthNames;
import 'package:datovka/ui/message_list.dart';
import 'package:datovka/ui/settings_dialog.dart';
import 'package:datovka/ui/sidebar.dart';
import 'package:datovka/data/app_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dev/demo_data.dart';

/// Drags with the mouse in small steps, like a real hand does.
Future<void> _mouseDrag(WidgetTester tester, double x, double dx) async {
  final g = await tester.startGesture(
    Offset(x, 450),
    kind: PointerDeviceKind.mouse,
  );
  for (var i = 0; i < 10; i++) {
    await g.moveBy(Offset(dx / 10, 0));
  }
  await g.up();
}

AppState _sample() => AppState(initialBoxes: demoBoxes, messages: demoMessages());

void main() {
  setUpAll(() {
    checkUpdatesOnStart = false;
  });

  testWidgets('desktop width shows three panes and the status line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    expect(find.text('Datovka NG'), findsOneWidget);
    expect(find.text('alfa'), findsOneWidget);
    expect(find.text('Přijaté'), findsWidgets);
    expect(find.textContaining('Vyberte zprávu'), findsOneWidget);
    await tester.tap(find.text(state.visible.first.subject).first);
    await tester.pumpAndSettle();
    expect(find.text('Přílohy'), findsOneWidget);
    expect(find.text('Vývoj je podporován NENDE.cz'), findsOneWidget);
    expect(find.text('Připraveno'), findsOneWidget);
    expect(find.text('verze $appVersion'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsNothing);
  });

  testWidgets('narrow width keeps the phone layout', (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(DatovkaApp(state: AppState()));
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.text('Přílohy'), findsNothing);
  });

  testWidgets('column widths can be dragged and are remembered', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'paneSidebarWidth': 300.0});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(DatovkaApp(state: _sample()));
    await tester.pumpAndSettle();
    final sidebar = find.byType(Sidebar);
    expect(tester.getSize(sidebar).width, 300);

    await _mouseDrag(tester, 300, 40);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 340);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneSidebarWidth'), 340);

    await _mouseDrag(tester, 340, -500);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 200, reason: 'never narrower');
  });

  testWidgets('clicking a visible message does not scroll the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final many = [
      for (var i = 0; i < 40; i++)
        Message(
          boxId: demoBoxes.first.id,
          dmId: '${9000 + i}',
          direction: Direction.received,
          subject: 'Zpráva $i',
          counterparty: 'Úřad $i',
          counterpartyAddress: 'Praha',
          delivered: DateTime(2026, 1, 1).subtract(Duration(days: i)),
          isRead: true,
          attachments: const [],
          tags: const [],
        ),
    ];
    final s = AppState(initialBoxes: demoBoxes, messages: many);
    await tester.pumpWidget(DatovkaApp(state: s));
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byType(MessageList),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    final position = tester.state<ScrollableState>(list.first).position;
    expect(position.pixels, 0);
    expect(position.maxScrollExtent, greaterThan(0));
    // A row near the bottom of the visible part of the list.
    final box = tester.getRect(list.first);
    await tester.tapAt(Offset(box.center.dx, box.top + box.height * 0.8));
    await tester.pumpAndSettle();
    expect(s.selectedId, isNotNull);
    expect(position.pixels, 0);
  });

  testWidgets('help opens from the status line', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(DatovkaApp(state: AppState()));
    await tester.tap(find.text('Nápověda'));
    await tester.pumpAndSettle();
    expect(find.text('Archiv'), findsOneWidget);
    expect(find.textContaining('nesmí'), findsWidgets);
  });

  testWidgets('search with no hit leaves the list empty', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    await tester.enterText(find.byType(TextField).first, 'nic-takoveho-neni');
    await tester.pump();
    expect(find.text('Nic nenalezeno'), findsOneWidget);
    expect(state.visible, isEmpty);
    await tester.tap(find.byTooltip('Smazat hledání'));
    await tester.pump();
    expect(state.query, isEmpty);
    expect(state.visible, isNotEmpty);
    expect(find.text(state.visible.first.subject), findsWidgets);
  });

  testWidgets('a contact opens messages with that box', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Message row(String id, Direction direction, String subject) => Message(
      boxId: 'moje',
      dmId: id,
      direction: direction,
      subject: subject,
      counterparty: 'Úřad',
      counterpartyAddress: '',
      counterpartyBoxId: 'urad1',
      delivered: DateTime(2026, 5, 1),
    );
    final state = AppState(
      messages: [
        row('1', Direction.received, 'Výzva od úřadu'),
        row('2', Direction.sent, 'Odpověď úřadu'),
        Message(
          boxId: 'moje',
          dmId: '3',
          direction: Direction.received,
          subject: 'Faktura od jiného',
          counterparty: 'Dodavatel',
          counterpartyAddress: '',
          counterpartyBoxId: 'jiny',
          delivered: DateTime(2026, 5, 2),
        ),
      ],
    );
    await tester.pumpWidget(DatovkaApp(state: state));
    await tester.tap(find.text('Adresář schránek'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Úřad'));
    await tester.pumpAndSettle();
    expect(find.text('Výzva od úřadu'), findsOneWidget);
    expect(find.text('Odpověď úřadu'), findsOneWidget);
    expect(find.text('Faktura od jiného'), findsNothing);
    expect(state.folder, Folder.all);
  });

  test('claude code notice says the text is sent', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'assistantKind': 'subscription',
    });
    final n = await assistantNotice();
    expect(n!.text, 'Text příloh může opustit tento počítač.');
  });

  test('an empty proxy is not replaced with the archive path', () {
    expect(
      argsWithDataDir('set_proxy', [''], '/tmp/archiv'),
      [''],
    );
    expect(
      argsWithDataDir('accounts', [''], '/tmp/archiv'),
      ['/tmp/archiv'],
    );
  });

  test('labels for the archive do not reveal a home directory', () {
    expect(ArchiveLocation.isLegacy('/tmp/schranka/.dsgui'), isTrue);
    expect(ArchiveLocation.isLegacy('/tmp/Archiv.datovka'), isFalse);
    expect(
      ArchiveLocation.storageLabel('/Library/Mobile Documents/Archiv.datovka'),
      'iCloud Drive',
    );
    expect(ArchiveLocation.storageLabel('/tmp/Documents/Archiv.datovka'), 'Dokumenty');
    expect(ArchiveLocation.packageName, 'Archiv.datovka');
  });

  test('a switched-off assistant does not ask for a message', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({'assistantKind': 'none'});
    await expectLater(
      analyzeMessage(null, demoMessages().first),
      throwsA(
        isA<UserError>().having(
          (e) => e.message,
          'message',
          contains('Asistent je vypnutý'),
        ),
      ),
    );
  });

  test('changing the login method asks for a new login', () async {
    final s = _sample();
    final box = s.boxes.firstWhere((b) => b.login != LoginMethod.mobileKey);
    await s.changeLogin(box, LoginMethod.mobileKey);
    final changed = s.boxes.firstWhere((b) => b.id == box.id);
    expect(changed.login, LoginMethod.mobileKey);
    expect(changed.session, Session.expired);
    expect(changed.name, box.name);
  });

  test('a password box without a stored password shows as logged out', () {
    const box = DataBox(
      id: 'abc',
      name: 'Firma',
      kind: 'Právnická osoba',
      username: 'abc',
      login: LoginMethod.password,
      session: Session.expired,
    );
    expect(box.canSyncUnattended, isFalse);
    expect(box.copyWith(session: Session.active).canSyncUnattended, isTrue);
  });

  test('any box can log out and stays out until it logs in', () {
    final s = _sample();
    final box = s.boxes.firstWhere((b) => b.session == Session.active);
    s.logout(box);
    expect(s.boxById(box.id)!.session, Session.expired);
    expect(s.boxById(box.id)!.canSyncUnattended, isFalse);
    s.loggedIn(box.id);
    expect(s.boxById(box.id)!.session, Session.active);
  });

  test('a note can be added, changed and removed', () {
    final s = _sample();
    final m = s.visible.first;
    s.setNote(m, '  Předáno účetní  ');
    expect(s.visible.firstWhere((x) => x.dmId == m.dmId).note, 'Předáno účetní');
    s.setNote(m, '');
    expect(s.visible.firstWhere((x) => x.dmId == m.dmId).note, isNull);
  });

  test('a note comes from the message row', () {
    final m = messageFromRow({'dm_id': 1, 'note': 'Zavolat'});
    expect(m.note, 'Zavolat');
    expect(messageFromRow({'dm_id': 2, 'note': ' '}).note, isNull);
  });

  test('a year or a month is a period, other ranges are not', () {
    expect(
      SearchFilter(from: DateTime(2025), to: DateTime(2025, 12, 31)).period,
      (year: 2025, month: null),
    );
    expect(
      SearchFilter(from: DateTime(2024, 2), to: DateTime(2024, 2, 29)).period,
      (year: 2024, month: 2),
    );
    expect(
      SearchFilter(from: DateTime(2025, 3, 5), to: DateTime(2025, 3, 31)).period,
      isNull,
    );
    expect(const SearchFilter().period, isNull);
  });

  test('choosing a year narrows the list and keeps the other years on offer', () {
    final s = _sample();
    s.folder = Folder.all;
    final all = s.visible.length;
    final years = {for (final k in s.months.keys) int.parse(k.substring(0, 4))};
    final y = s.visible.first.delivered.year;
    s.showPeriod(y);
    expect(s.filter.period, (year: y, month: null));
    expect(s.visible.every((m) => m.delivered.year == y), isTrue);
    expect({for (final k in s.months.keys) int.parse(k.substring(0, 4))}, years);
    final mo = s.visible.first.delivered.month;
    s.showPeriod(y, mo);
    expect(s.visible.every((m) => m.delivered.month == mo), isTrue);
    s.showPeriod(null);
    expect(s.visible.length, all);
  });

  test('links to NENDE say where the visit came from', () {
    final u = Uri.parse(nendeLink('status-bar'));
    expect(u.host, 'nende.cz');
    expect(u.queryParameters['utm_source'], 'datovka-ng');
    expect(u.queryParameters['utm_medium'], 'app');
    expect(u.queryParameters['utm_campaign'], 'status-bar');
    expect(u.queryParameters['utm_content'], endsWith('-$appVersion'));
  });

  testWidgets('a locked app shows only the lock until unlocked', (
    tester,
  ) async {
    AppLock.enabled.value = true;
    addTearDown(() => AppLock.enabled.value = false);
    await tester.pumpWidget(
      MaterialApp(home: AppLock(child: const Text('obsah schránky'))),
    );
    await tester.pump();
    expect(find.text('Datovka je zamčená'), findsOneWidget);
    expect(find.text('obsah schránky'), findsNothing);
    // Without Face ID in the test the button keeps it locked.
    await tester.tap(find.text('Odemknout'));
    await tester.pump();
    expect(find.text('Datovka je zamčená'), findsOneWidget);
  });

  testWidgets('the attachment reading fits a phone screen', (tester) async {
    SharedPreferences.setMockInitialValues({'assistantKind': 'api'});
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    final ctx = tester.element(find.byType(Scaffold).first);
    showAiAnalysis(ctx, state.visible.first);
    await tester.pumpAndSettle();
    expect(find.text('Rozbor příloh'), findsOneWidget);
    expect(find.text('Přidat do kalendáře'), findsOneWidget);
  });

  testWidgets('the folder tree opens years and months by the arrow only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    final all = state.visible.length;
    final first = state.visible.first.delivered;
    final (y, mo) = (first.year, first.month);
    expect(find.text('$y'), findsNothing);

    // The arrow opens the years and leaves the list as it is.
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    expect(find.text('$y'), findsOneWidget);
    expect(state.filter.period, isNull);
    expect(state.visible.length, all);

    // The year's own arrow shows its months.
    final yearRow = find.ancestor(
      of: find.text('$y'),
      matching: find.byType(Row),
    ).first;
    await tester.tap(
      find.descendant(of: yearRow, matching: find.byIcon(Icons.chevron_right)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(monthNames[mo - 1]));
    await tester.pumpAndSettle();
    expect(state.filter.period, (year: y, month: mo));
    expect(state.folder, Folder.inbox);
    expect(find.text('${monthNames[mo - 1]} $y'), findsOneWidget);
    expect(state.filter.activeBesidesPeriod, isFalse);

    // The name of the folder shows all of it again.
    await tester.tap(find.text('Přijaté').first);
    await tester.pumpAndSettle();
    expect(state.filter.period, isNull);
    expect(state.visible.length, all);
  });

  testWidgets('the update check answers under its button', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    final ctx = tester.element(find.byType(Scaffold).first);
    showSettings(ctx, state);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aktualizace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zkontrolovat'));
    // Tests have no network: GitHub answers 400, which must read as an
    // error, never as "up to date", and stay inside the dialog.
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 1)));
    await tester.pumpAndSettle();
    expect(find.textContaining('GitHub odpověděl chybou'), findsOneWidget);
    expect(find.text('Máte nejnovější verzi $appVersion.'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the status line stays above the home indicator', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(DatovkaApp(state: _sample()));
    final nende = tester.getRect(find.text('NENDE.cz'));
    final ready = tester.getRect(find.text('Připraveno'));
    expect(nende.bottom, lessThanOrEqualTo(844 - 34));
    expect(nende.right, lessThanOrEqualTo(390 - 8));
    expect(ready.left, greaterThanOrEqualTo(8));
  });

  test('the deadline count follows the chosen box', () {
    final s = _sample();
    final messages = demoMessages();
    expect(s.openDeadlines, messages.where((m) => m.deadline != null).length);
    for (final b in s.boxes) {
      s.selectBox(b.id);
      expect(
        s.openDeadlines,
        messages.where((m) => m.boxId == b.id && m.deadline != null).length,
        reason: b.name,
      );
    }
    expect(
      s.boxes.any((b) {
        s.selectBox(b.id);
        return s.openDeadlines == 0;
      }),
      isTrue,
      reason: 'the sample has a box without deadlines',
    );
  });

  testWidgets('the message menu marks a message settled and deletes it here', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    final m = state.visible.first;
    final row = find.text(m.subject).first;

    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    for (final label in ['Označit', 'Uložit', 'ISDS', 'Smazat jen v počítači…']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Označit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vyřízeno'));
    await tester.pumpAndSettle();
    expect(
      state.visible.firstWhere((x) => x.dmId == m.dmId).processState,
      ProcessState.settled,
    );
    expect(find.byIcon(Icons.task_alt), findsOneWidget);

    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Smazat jen v počítači…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Smazat v počítači'));
    await tester.pumpAndSettle();
    expect(state.visible.where((x) => x.dmId == m.dmId), isEmpty);
  });

  test('a time stamp can be renewed only in its last year and a half', () {
    StampExpiry at(int days) => StampExpiry(
      box: demoBoxes.first,
      dmId: '1',
      expires: DateTime.now().add(Duration(days: days)),
      subject: '',
      counterparty: '',
      received: true,
    );
    expect(at(400).renewable, isTrue);
    expect(at(600).renewable, isFalse);
  });

  testWidgets('a phone lists the boxes alphabetically, without dragging', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    expect(find.byType(ReorderableListView), findsNothing);
    final names = [for (final b in state.boxes) b.name]
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final ys = [
      for (final n in names)
        tester
            .getTopLeft(
              find.descendant(of: find.byType(Sidebar), matching: find.text(n)),
            )
            .dy,
    ];
    expect(ys, [...ys]..sort());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a box can be removed from its menu', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    final box = state.boxes.last;
    final count = state.boxes.length;
    await tester.tap(
      find.descendant(of: find.byType(Sidebar), matching: find.text(box.name)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odebrat schránku…'));
    await tester.pumpAndSettle();
    expect(find.text('Odebrat schránku ${box.name}?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Odebrat'));
    await tester.pumpAndSettle();
    expect(state.boxes.length, count - 1);
    expect(state.boxes.any((b) => b.id == box.id), isFalse);
  });

  test('a download keeps saying where the archive is', () async {
    final state = _sample();
    state.sync = const SyncState(storageName: 'původní Datovka');
    final run = state.runSync();
    expect(state.sync.running, isTrue);
    expect(state.sync.storageName, 'původní Datovka');
    await run;
    expect(state.sync.storageName, 'původní Datovka');
  });

  for (final width in [1100.0, 390.0]) {
    testWidgets('text size and dark look apply after saving ($width)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = _sample();
      await tester.pumpWidget(DatovkaApp(state: state));
      MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app().themeMode, ThemeMode.system);

      final ctx = tester.element(find.byType(Scaffold).first);
      showSettings(ctx, state);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zobrazení'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Větší'));
      await tester.tap(find.text('Tmavý'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();

      expect(app().themeMode, ThemeMode.dark);
      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byType(Home)),
      );
      expect(scaler.scale(10), closeTo(10.8, 0.01));
      final saved = await Settings.load();
      expect((saved.textSize, saved.themeMode), (1, ThemeMode.dark));
    });
  }

  testWidgets('a new box cannot pick the code from an app, ISDS ends it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = _sample();
    await tester.pumpWidget(DatovkaApp(state: state));
    showAddBoxDialog(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();
    expect(find.text(LoginMethod.passwordSms.label), findsOneWidget);
    expect(find.text(LoginMethod.passwordOtp.label), findsNothing);
  });

  testWidgets('a suspicious message warns and a received one can be reported', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final messages = demoMessages();
    final i = messages.indexWhere((m) => m.direction == Direction.received);
    final m0 = messages[i];
    messages[i] = Message(
      boxId: m0.boxId,
      dmId: m0.dmId,
      direction: m0.direction,
      subject: m0.subject,
      counterparty: m0.counterparty,
      counterpartyAddress: m0.counterpartyAddress,
      delivered: m0.delivered,
      suspicious: true,
    );
    final state = AppState(initialBoxes: demoBoxes, messages: messages);
    await tester.pumpWidget(DatovkaApp(state: state));
    state.open(m0.dmId);
    await tester.pumpAndSettle();
    expect(find.textContaining('ISDS označil tuto zprávu jako podezřelou'), findsOneWidget);
    expect(find.byIcon(Icons.report_outlined), findsWidgets);

    await tester.tap(find.text(m0.subject).first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ISDS'));
    await tester.pumpAndSettle();
    expect(find.text('Nahlásit jako podezřelou (spam)…'), findsOneWidget);
  });
}
