import 'package:datovka/data/app_state.dart';
import 'package:datovka/data/mailbox.dart';
import 'package:datovka/data/models.dart';
import 'package:datovka/data/updates.dart';
import 'package:datovka/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dev/demo_data.dart';

void main() {
  setUpAll(() => checkUpdatesOnStart = false);

  test('the status line says which sent messages were accepted', () {
    expect(deliveredNotice([]), isNull);
    expect(deliveredNotice(['Odvolání']), 'Zpráva „Odvolání“ byla doručena.');
    expect(deliveredNotice(['a', 'b']), 'Doručeny 2 odeslané zprávy.');
    expect(deliveredNotice(['a', 'b', 'c', 'd', 'e']), 'Doručeno 5 odeslaných zpráv.');
  });

  test('a row from the archive keeps when the recipient accepted it', () {
    final m = messageFromRow({
      'username': 'abc',
      'dm_id': 42,
      'direction': 'sent',
      'delivery_time': '2026-10-29T19:59:16.263Z',
      'acceptance_time': '2026-10-30T08:15:00Z',
    });
    expect(m.accepted, DateTime.utc(2026, 10, 30, 8, 15).toLocal());
    final waiting = messageFromRow({
      'username': 'abc',
      'dm_id': 43,
      'direction': 'sent',
      'delivery_time': '2026-10-29T19:59:16.263Z',
    });
    expect(waiting.accepted, isNull);
  });

  testWidgets('a sent message shows delivery and acceptance apart', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final messages = demoMessages();
    final i = messages.indexWhere((m) => m.direction == Direction.sent);
    final m0 = messages[i];
    messages[i] = Message(
      boxId: m0.boxId,
      dmId: m0.dmId,
      direction: m0.direction,
      subject: m0.subject,
      counterparty: m0.counterparty,
      counterpartyAddress: m0.counterpartyAddress,
      delivered: m0.delivered,
    );
    final state = AppState(initialBoxes: demoBoxes, messages: messages);
    await tester.pumpWidget(DatovkaApp(state: state));
    state.open(m0.dmId);
    await tester.pumpAndSettle();
    expect(find.text('Dodáno'), findsOneWidget);
    expect(find.text('zatím ne'), findsOneWidget);
  });
}
