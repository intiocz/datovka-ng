// iPads upright and on their side: the message opens next to the list, and
// nothing overflows on the main screen or in the larger dialogs.
import '../dev/demo_data.dart';

import 'package:datovka/data/app_state.dart';
import 'package:datovka/data/updates.dart';
import 'package:datovka/main.dart';
import 'package:datovka/ui/compose.dart';
import 'package:datovka/ui/message_detail.dart';
import 'package:datovka/ui/message_list.dart';
import 'package:datovka/ui/settings_dialog.dart';
import 'package:datovka/ui/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => checkUpdatesOnStart = false);

  const ipads = {
    'iPad mini': Size(744, 1133),
    'iPad 11″': Size(820, 1180),
    'iPad 13″': Size(1032, 1376),
  };

  Future<AppState> start(WidgetTester tester, Size size) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(initialBoxes: demoBoxes, messages: demoMessages());
    await tester.pumpWidget(DatovkaApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  for (final MapEntry(key: name, value: upright) in ipads.entries) {
    for (final size in [upright, upright.flipped]) {
      final how = size.width < size.height ? 'na výšku' : 'na šířku';

      testWidgets('$name $how: zpráva se otevře vedle seznamu', (tester) async {
        await start(tester, size);
        await tester.tap(
          find.textContaining('Výzva k podání vysvětlení').first,
        );
        await tester.pumpAndSettle();
        expect(find.byType(MessageList), findsOneWidget);
        expect(find.byType(MessageDetail), findsOneWidget);
        // Upright small iPads keep the boxes in the menu, the rest beside.
        expect(
          find.byType(Sidebar),
          size.width >= 980 ? findsOneWidget : findsNothing,
        );
      });

      for (final MapEntry(key: dialog, value: open) in {
        'nastavení': (BuildContext c, AppState s) => showSettings(c, s),
        'psaní zprávy': (BuildContext c, AppState s) => showCompose(c),
      }.entries) {
        testWidgets('$name $how: $dialog se vejde', (tester) async {
          final state = await start(tester, size);
          open(tester.element(find.byType(Scaffold).first), state);
          await tester.pumpAndSettle();
        });
      }
    }
  }
}
