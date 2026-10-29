import 'package:datovka/data/mailbox.dart';
import 'package:datovka/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fold strips Czech diacritics', () {
    expect(foldText('Příliš žluťoučký'), 'prilis zlutoucky');
  });

  test('message row keeps direction, refs and tags', () {
    final m = messageFromRow({
      'username': 'nv8q2k',
      'dm_id': 42,
      'direction': 'sent',
      'annotation': 'Věc',
      'recipient': 'Úřad',
      'recipient_box_id': 'urad1',
      'recipient_address': 'Praha',
      'sender_ref_number': 'NAŠE',
      'recipient_ref_number': 'JEJICH',
      'delivery_time': '2026-05-01T10:00:00.000Z',
      'read_locally': false,
      'attachments': 2,
      'tags': ['Spor'],
      'deadline': '2026-06-01',
    });
    expect(m.boxId, 'nv8q2k');
    expect(m.dmId, '42');
    expect(m.direction, Direction.sent);
    expect(m.isRead, isTrue);
    expect(m.counterparty, 'Úřad');
    expect(m.ourRef, 'NAŠE');
    expect(m.theirRef, 'JEJICH');
    expect(m.tags, ['Spor']);
    expect(m.attachments, hasLength(2));
    expect(m.deadline, isNotNull);
  });

  test('inbox hides sent messages', () {
    final messages = [
      Message(
        boxId: 'a',
        dmId: '1',
        direction: Direction.received,
        subject: 'Přišlo',
        counterparty: 'Úřad',
        counterpartyAddress: '',
        delivered: DateTime(2026, 5, 1),
        isRead: false,
      ),
      Message(
        boxId: 'a',
        dmId: '2',
        direction: Direction.sent,
        subject: 'Odešlo',
        counterparty: 'Úřad',
        counterpartyAddress: '',
        delivered: DateTime(2026, 5, 2),
      ),
    ];
    final visible = visibleMessages(
      messages: messages,
      boxId: 'a',
      folder: Folder.inbox,
      query: '',
      filter: const SearchFilter(),
    );
    expect(visible.map((m) => m.dmId), ['1']);
  });
}
