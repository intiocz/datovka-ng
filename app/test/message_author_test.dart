import 'package:datovka/ui/message_author.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the sender of a message reads as labelled rows', () {
    final rows = messageAuthorRows({
      'dmMessageAuthor': {
        'maItem': [
          {'key': 'userType', 'value': 'ENTRUSTED_USER'},
          {'key': 'pnGivenNames', 'value': 'Jan Bohuslav'},
          {'key': 'pnLastName', 'value': 'Šimek'},
          {'key': 'biDate', 'value': '1980-03-07'},
          {'key': 'robIdent', 'value': 'true'},
        ],
      },
    });
    expect(rows, [
      ('Role', 'Pověřená osoba'),
      ('Jméno', 'Jan Bohuslav Šimek'),
      ('Datum narození', '7. 3. 1980'),
      ('Ověřeno v registru obyvatel', 'ano'),
    ]);
  });

  test('a records service shows as an application, unknown roles as they are', () {
    expect(
      messageAuthorRows({
        'maItem': [
          {'key': 'userType', 'value': 'VIRTUAL'},
          {'key': 'pnLastName', 'value': 'Spisová služba'},
        ],
      }),
      [('Role', 'Aplikace (spisová služba)'), ('Aplikace', 'Spisová služba')],
    );
    expect(
      messageAuthorRows({
        'maItem': {'key': 'userType', 'value': 'Spisová služba'},
      }),
      [('Role', 'Spisová služba')],
    );
    expect(messageAuthorRows(null), isEmpty);
  });
}
