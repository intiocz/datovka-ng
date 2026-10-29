import 'package:flutter/material.dart';

import '../theme.dart';

/// Roles of the sender in the box (`userType` of `GetMessageAuthor2`).
const _roles = {
  'PRIMARY_USER': 'Oprávněná osoba (vlastník, statutární zástupce)',
  'LIQUIDATOR': 'Likvidátor',
  'RECEIVER': 'Nucený správce',
  'GUARDIAN': 'Opatrovník',
  'ENTRUSTED_USER': 'Pověřená osoba',
  'ADMINISTRATOR': 'Administrátor schránky',
  'OFFICIAL': 'Systémová zpráva ISDS',
  'VIRTUAL': 'Aplikace (spisová služba)',
};

/// The `key`/`value` items of `GetMessageAuthor2` as labelled rows, in the
/// order a person reads them.
List<(String, String)> messageAuthorRows(dynamic data) {
  final items = <String, String>{};
  void collect(dynamic d) {
    if (d is Map) {
      final k = d['key'], v = d['value'];
      if (k is String && v != null && '$v'.trim().isNotEmpty) {
        items[k] = '$v'.trim();
        return;
      }
      d.values.forEach(collect);
    } else if (d is List) {
      d.forEach(collect);
    }
  }

  collect(data);
  final virtual = items['userType'] == 'VIRTUAL';
  final name = [
    items['pnGivenNames'],
    items['pnLastName'],
  ].whereType<String>().join(' ');
  final born = items['biDate'];
  final place = [
    items['biCity'],
    items['biCounty'],
  ].whereType<String>().join(', ');
  return [
    if (items['userType'] case final role?) ('Role', _roles[role] ?? role),
    if (name.isNotEmpty) (virtual ? 'Aplikace' : 'Jméno', name),
    if (born != null) ('Datum narození', _date(born)),
    if (place.isNotEmpty) ('Místo narození', place),
    if (items['fullAddress'] case final a?) ('Adresa', a),
    if (items['adCode'] case final c?) ('Adresní kód RÚIAN', c),
    if (items['robIdent'] case final r?)
      (
        'Ověřeno v registru obyvatel',
        r == 'true' || r == '1' ? 'ano' : 'ne',
      ),
  ];
}

String _date(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : '${d.day}. ${d.month}. ${d.year}';
}

/// Who sent a message, label above value so it fits a phone.
class MessageAuthorView extends StatelessWidget {
  final dynamic data;

  const MessageAuthorView({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final rows = messageAuthorRows(data);
    if (rows.isEmpty) {
      return Text('ISDS o odesílateli nic neuvádí.', style: text.bodyMedium);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: text.bodySmall?.copyWith(color: t.inkMuted),
                ),
                Text(value, style: text.bodyMedium),
              ],
            ),
          ),
      ],
    );
  }
}
