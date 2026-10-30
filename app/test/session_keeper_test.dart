import 'package:datovka/data/models.dart';
import 'package:datovka/data/session_keeper.dart';
import 'package:flutter_test/flutter_test.dart';

DataBox _box(String id, LoginMethod login, Session session) => DataBox(
  id: id,
  name: id,
  kind: 'PO',
  username: 'u-$id',
  login: login,
  session: session,
);

void main() {
  final boxes = [
    _box('heslo', LoginMethod.password, Session.active),
    _box('klic', LoginMethod.mobileKey, Session.active),
    _box('sms', LoginMethod.passwordSms, Session.active),
    _box('vyprsela', LoginMethod.mobileKey, Session.expired),
  ];

  test('only live logins that need the user are kept', () {
    expect(
      [for (final b in SessionKeeper.targets(boxes)) b.id],
      ['klic', 'sms'],
    );
  });

  test('a session ISDS ended shows as such, a network failure does not', () async {
    final asked = <String>[];
    final ended = <String>[];
    final answers = {'u-klic': false, 'u-sms': null};
    await SessionKeeper(
      ping: (u) async {
        asked.add(u);
        return answers[u];
      },
      boxes: () => boxes,
      expired: (b) => ended.add(b.id),
    ).tick();
    expect(asked, ['u-klic', 'u-sms']);
    expect(ended, ['klic']);
  });

  test('a failing call keeps the session and the others are asked', () async {
    final ended = <String>[];
    final asked = <String>[];
    await SessionKeeper(
      ping: (u) async {
        asked.add(u);
        if (u == 'u-klic') throw Exception('bez sítě');
        return true;
      },
      boxes: () => boxes,
      expired: (b) => ended.add(b.id),
    ).tick();
    expect(asked, ['u-klic', 'u-sms']);
    expect(ended, isEmpty);
  });
}
