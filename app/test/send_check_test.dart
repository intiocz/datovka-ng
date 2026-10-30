// A message whose files ISDS would refuse cannot be sent; the reason shows
// under the list of documents. The rules themselves are tested in the core
// (core/src/isds/rules.rs); here the core's answer is stood in for.
import 'package:datovka/data/app_state.dart';
import 'package:datovka/data/file_check.dart';
import 'package:datovka/data/updates.dart';
import 'package:datovka/main.dart';
import 'package:datovka/ui/compose.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dev/demo_data.dart';

void main() {
  setUpAll(() => checkUpdatesOnStart = false);

  testWidgets('a file ISDS refuses blocks sending and says why', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(initialBoxes: demoBoxes, messages: demoMessages());
    final checked = <List<String>>[];
    state.fileChecker = (files, recipients) async {
      checked.add(files);
      return FileCheck(
        problems: [
          for (final f in files)
            if (f.endsWith('.exe'))
              FileProblem(
                error: true,
                file: f,
                text: 'program.exe: formát .exe ISDS nepřijímá.',
              ),
        ],
      );
    };
    await tester.pumpWidget(DatovkaApp(state: state));
    showCompose(
      tester.element(find.byType(Scaffold).first),
      Draft(
        fromBoxId: demoBoxes.first.id,
        recipients: const [(boxId: 'abc1234', name: 'Úřad')],
        subject: 'Žádost',
        files: const ['/tmp/zadost.pdf', '/tmp/program.exe'],
      ),
    );
    await tester.pumpAndSettle();

    expect(checked, isNotEmpty, reason: 'files are checked when the form opens');
    expect(find.text('program.exe: formát .exe ISDS nepřijímá.'), findsOneWidget);

    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ISDS by zprávu odmítl'), findsOneWidget);

    // Without the file the problem goes away.
    final remove = find.descendant(
      of: find.widgetWithText(ListTile, 'program.exe'),
      matching: find.byIcon(Icons.close),
    );
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(checked.last, ['/tmp/zadost.pdf']);
    expect(find.text('program.exe: formát .exe ISDS nepřijímá.'), findsNothing);
  });
}
