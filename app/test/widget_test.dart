import 'package:flutter/material.dart';
import 'package:datovka/data/app_state.dart';
import 'package:datovka/data/updates.dart';
import 'package:datovka/main.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dev/demo_data.dart';

void main() {
  setUpAll(() {
    checkUpdatesOnStart = false;
  });

  testWidgets('shows inbox and opens a message', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(initialBoxes: demoBoxes, messages: demoMessages());
    await tester.pumpWidget(DatovkaApp(state: state));
    expect(find.text('Přijaté'), findsWidgets);

    final subject = state.visible.first.subject;
    await tester.tap(find.text(subject));
    await tester.pumpAndSettle();
    expect(find.text('Přílohy'), findsOneWidget);
  });

  testWidgets('reply opens a prefilled compose form', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(initialBoxes: demoBoxes, messages: demoMessages());
    await tester.pumpWidget(DatovkaApp(state: state));
    final m = state.visible.first;
    await tester.tap(find.text(m.subject));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odpovědět'));
    await tester.pumpAndSettle();
    expect(find.text('Odpověď'), findsOneWidget);
    expect(find.text('Re: ${m.subject}'), findsOneWidget);
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('přidejte aspoň jeden dokument'),
      findsOneWidget,
    );
  });
}
