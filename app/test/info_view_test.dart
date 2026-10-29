import 'package:datovka/theme.dart';
import 'package:datovka/ui/info_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> show(WidgetTester tester, Object data) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: InfoView(data: data)),
  ),
);

void main() {
  testWidgets('message author: maltem pairs read as labelled rows', (
    tester,
  ) async {
    await show(tester, {
      'dmMessageAuthor': {
        'maltem': [
          {'key': 'userType', 'value': 'ENTRUSTED_USER'},
          {'key': 'pnLastName', 'value': 'Nováková'},
          {'key': 'robIdent', 'value': 'true'},
        ],
      },
    });
    expect(find.text('Role uživatele'), findsOneWidget);
    expect(find.text('Pověřená osoba'), findsOneWidget);
    expect(find.text('Příjmení'), findsOneWidget);
    expect(find.text('Nováková'), findsOneWidget);
    expect(find.text('ano'), findsOneWidget);
    expect(find.textContaining('maltem'), findsNothing);
    expect(find.text('key'), findsNothing);
  });

  testWidgets('a single maltem pair', (tester) async {
    await show(tester, {
      'dmMessageAuthor': {
        'maltem': {'key': 'userType', 'value': 'PRIMARY_USER'},
      },
    });
    expect(find.text('Oprávněná osoba'), findsOneWidget);
    expect(find.text('value'), findsNothing);
  });
}
