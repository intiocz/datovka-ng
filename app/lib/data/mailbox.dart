import 'models.dart';

/// Czech diacritics stripped, then lowercased. Matches `legacy/query.rs`.
String foldText(String s) {
  const from = 'áčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ';
  const to = 'acdeeinorstuuyzACDEEINORSTUUYZ';
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    final i = from.indexOf(c);
    b.write(i >= 0 ? to[i] : c);
  }
  return b.toString().toLowerCase();
}

/// One row of `dk_message_query`.
Message messageFromRow(Map<String, dynamic> r) {
  final sent = r['direction'] == 'sent';
  final time =
      DateTime.tryParse(r['delivery_time'] as String? ?? '') ??
      DateTime.tryParse(r['acceptance_time'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);
  final deadline = DateTime.tryParse('${r['deadline'] ?? ''}');
  return Message(
    boxId: r['username'] as String? ?? '',
    dmId: '${r['dm_id']}',
    direction: sent ? Direction.sent : Direction.received,
    subject: r['annotation'] as String? ?? '(bez věci)',
    counterparty: (sent ? r['recipient'] : r['sender']) as String? ?? '',
    counterpartyBoxId:
        (sent ? r['recipient_box_id'] : r['sender_box_id']) as String?,
    counterpartyAddress:
        (sent ? r['recipient_address'] : r['sender_address']) as String? ?? '',
    delivered: time.toLocal(),
    isRead: sent || (r['read_locally'] as bool? ?? false),
    ourRef:
        (sent ? r['sender_ref_number'] : r['recipient_ref_number']) as String?,
    theirRef:
        (sent ? r['recipient_ref_number'] : r['sender_ref_number']) as String?,
    attachments: List.generate(
      (r['attachments'] as num?)?.toInt() ?? 0,
      (_) => const Attachment('', 0),
    ),
    tags: [for (final t in (r['tags'] as List? ?? const [])) '$t'],
    deadline: deadline,
    note: (r['note'] as String?)?.trim().isEmpty ?? true
        ? null
        : r['note'] as String,
    processState:
        ProcessState.values.elementAtOrNull(
          (r['process_state'] as num?)?.toInt() ?? 0,
        ) ??
        ProcessState.unsettled,
    suspicious: r['suspicious'] == true,
    accepted: DateTime.tryParse(
      r['acceptance_time'] as String? ?? '',
    )?.toLocal(),
  );
}

class MailboxPage {
  final List<Message> messages;
  final int total;
  final Map<String, int> unread;
  final int deadlineCount;

  /// Messages with a deadline per box (username).
  final Map<String, int> deadlines;
  final List<Contact> contacts;
  final List<String> allTags;

  /// `YYYY-MM` → number of messages, ignoring the chosen date range.
  final Map<String, int> months;

  const MailboxPage({
    required this.messages,
    required this.total,
    required this.unread,
    required this.deadlineCount,
    this.deadlines = const {},
    required this.contacts,
    required this.allTags,
    this.months = const {},
  });

  factory MailboxPage.fromJson(Map<String, dynamic> j) {
    final unread = <String, int>{};
    final rawUnread = j['unread'];
    if (rawUnread is Map) {
      for (final e in rawUnread.entries) {
        unread['${e.key}'] = (e.value as num).toInt();
      }
    }
    return MailboxPage(
      messages: [
        for (final r in (j['messages'] as List? ?? const []))
          messageFromRow((r as Map).cast<String, dynamic>()),
      ],
      total: (j['total'] as num?)?.toInt() ?? 0,
      unread: unread,
      deadlineCount: (j['deadline_count'] as num?)?.toInt() ?? 0,
      deadlines: {
        for (final e in ((j['deadlines'] as Map?) ?? const {}).entries)
          '${e.key}': (e.value as num).toInt(),
      },
      contacts: [
        for (final c in (j['contacts'] as List? ?? const []))
          Contact(
            boxId: (c as Map)['box_id'] as String? ?? '',
            name: c['name'] as String? ?? '',
            address: c['address'] as String? ?? '',
            count: (c['count'] as num?)?.toInt() ?? 0,
            last:
                DateTime.tryParse(c['last'] as String? ?? '')?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
      ],
      allTags: [for (final t in (j['all_tags'] as List? ?? const [])) '$t'],
      months: {
        for (final e in ((j['months'] as Map?) ?? const {}).entries)
          '${e.key}': (e.value as num).toInt(),
      },
    );
  }
}

/// In-memory filter used when the core is absent. The live app asks the core.
List<Message> visibleMessages({
  required List<Message> messages,
  required String? boxId,
  required Folder folder,
  required String query,
  required SearchFilter filter,
  String? partyBoxId,
}) {
  final words = foldText(query.trim())
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  final list = messages.where((m) {
    if (boxId != null && m.boxId != boxId) return false;
    switch (folder) {
      case Folder.inbox:
        if (m.direction != Direction.received) return false;
      case Folder.sent:
        if (m.direction != Direction.sent) return false;
      case Folder.deadlines:
        if (m.deadline == null) return false;
      case Folder.all:
        break;
      case Folder.drafts:
        return false;
    }
    if (filter.from != null && m.delivered.isBefore(filter.from!)) return false;
    if (filter.to != null &&
        !m.delivered.isBefore(filter.to!.add(const Duration(days: 1)))) {
      return false;
    }
    if (filter.unreadOnly && (m.isRead || m.direction == Direction.sent)) {
      return false;
    }
    if (filter.withDeadline && m.deadline == null) return false;
    if (filter.tag != null && !m.tags.contains(filter.tag)) return false;
    if (partyBoxId != null &&
        partyBoxId.isNotEmpty &&
        m.counterpartyBoxId != partyBoxId) {
      return false;
    }
    if (words.isEmpty) return true;
    final hay = foldText(
      '${m.subject} ${m.counterparty} ${m.counterpartyAddress} ${m.counterpartyBoxId ?? ''} '
      '${m.dmId} ${m.ourRef ?? ''} ${m.theirRef ?? ''} ${m.tags.join(' ')}',
    );
    return words.every(hay.contains);
  }).toList();
  if (folder == Folder.deadlines) {
    list.sort((a, b) => a.deadline!.compareTo(b.deadline!));
  } else {
    list.sort((a, b) => b.delivered.compareTo(a.delivered));
  }
  return list;
}

List<Contact> contactsFrom(List<Message> messages) {
  final byId = <String, Contact>{};
  for (final m in messages) {
    final id = m.counterpartyBoxId;
    if (id == null || id.isEmpty) continue;
    final c = byId[id];
    if (c == null) {
      byId[id] = Contact(
        boxId: id,
        name: m.counterparty,
        address: m.counterpartyAddress,
        count: 1,
        last: m.delivered,
      );
    } else {
      final newer = m.delivered.isAfter(c.last);
      byId[id] = Contact(
        boxId: id,
        name: newer && m.counterparty.isNotEmpty ? m.counterparty : c.name,
        address: newer && m.counterpartyAddress.isNotEmpty
            ? m.counterpartyAddress
            : c.address,
        count: c.count + 1,
        last: newer ? m.delivered : c.last,
      );
    }
  }
  return byId.values.toList()..sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : b.last.compareTo(a.last);
  });
}
