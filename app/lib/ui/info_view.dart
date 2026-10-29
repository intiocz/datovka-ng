import 'package:flutter/material.dart';

import '../theme.dart';

/// Czech labels for ISDS fields shown in information dialogs.
const _labels = {
  'dbID': 'ID schránky',
  'dbType': 'Typ schránky',
  'ic': 'IČO',
  'firmName': 'Název',
  'pnGivenNames': 'Jméno',
  'pnFirstName': 'Jméno',
  'pnMiddleName': 'Další jméno',
  'pnLastName': 'Příjmení',
  'pnLastNameAtBirth': 'Rodné příjmení',
  'biDate': 'Datum narození',
  'biCity': 'Místo narození',
  'biCounty': 'Okres narození',
  'biState': 'Stát narození',
  'adCity': 'Obec',
  'adDistrict': 'Část obce',
  'adStreet': 'Ulice',
  'adNumberInStreet': 'Číslo orientační',
  'adNumberInMunicipality': 'Číslo popisné',
  'adZipCode': 'PSČ',
  'adState': 'Stát',
  'adCode': 'Kód adresního místa',
  'nationality': 'Státní občanství',
  'dbIdOVM': 'ID OVM',
  'dbState': 'Stav schránky',
  'dbOpenAddressing': 'Otevřené adresování (PDZ)',
  'dbUpperID': 'Nadřízená schránka',
  'userType': 'Role uživatele',
  'userPrivils': 'Oprávnění',
  'userID': 'ID uživatele',
  'caStreet': 'Kontaktní ulice',
  'caCity': 'Kontaktní obec',
  'caZipCode': 'Kontaktní PSČ',
  'caState': 'Kontaktní stát',
  'currentCredit': 'Aktuální kredit (haléře)',
  'notifEmail': 'E-mail pro upozornění',
  'ciRecord': 'Pohyby kreditu',
  'ciEventTime': 'Čas',
  'ciEventType': 'Událost',
  'ciCreditChange': 'Změna (haléře)',
  'ciCreditAfter': 'Zůstatek (haléře)',
  'dmAuthor': 'Autor zprávy',
  'userName': 'Uživatel',
  'dmEventTime': 'Čas',
  'dmEventDescr': 'Událost',
  'dtType': 'Typ trezoru',
  'dtCapacity': 'Kapacita',
  'dtFrom': 'Platnost od',
  'dtTo': 'Platnost do',
  'dtCapacityUsed': 'Využito',
  'dbUserInfo': 'Uživatel',
  'dbUsers': 'Uživatelé',
  'dbOwnerInfo': 'Vlastník schránky',
  'dbOwnerInfoExt2': 'Vlastník schránky',
  'dbUserInfoExt2': 'Uživatel',
  'pdzType': 'Typ platby PDZ',
  'pdzRecip': 'Platba příjemcem',
  'pdzPayer': 'Plátce',
  'pdzExpire': 'Platnost',
  'pdzCnt': 'Počet zpráv',
  'odzIdent': 'Identifikátor odpovědi',
  'dmMessageAuthor': 'Odesílatel',
  'fullAddress': 'Adresa',
  'robIdent': 'Ověřen v registru obyvatel',
};

String label(String key) => _labels[key] ?? key.replaceFirst('@', '');

/// Czech wording of ISDS code values (`userType` and the like).
const _values = {
  'PRIMARY_USER': 'Oprávněná osoba',
  'ENTRUSTED_USER': 'Pověřená osoba',
  'ADMINISTRATOR': 'Administrátor',
  'OFFICIAL': 'Systém ISDS',
  'OFFICIAL_CERT': 'Systém ISDS (certifikát)',
  'VIRTUAL': 'Spisová služba',
  'LIQUIDATOR': 'Likvidátor',
  'RECEIVER': 'Nucený správce',
  'GUARDIAN': 'Opatrovník',
  'true': 'ano',
  'false': 'ne',
};

String value(Object v) => _values['$v'] ?? '$v';

/// Shows a JSON value returned by the core as a readable list of rows.
class InfoView extends StatelessWidget {
  final dynamic data;

  const InfoView({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    _collect(context, data, 0, rows);
    if (rows.isEmpty) {
      return Text(
        'ISDS nevrátil žádné údaje.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  void _collect(
    BuildContext context,
    dynamic v,
    int depth,
    List<Widget> out, [
    String? key,
  ]) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    if (v == null) return;
    // Version 2 services wrap fields as `<maltem><key/><value/></maltem>`.
    if (v is Map &&
        v.length == 2 &&
        v['key'] is String &&
        v.containsKey('value')) {
      _collect(context, v['value'], depth, out, v['key'] as String);
      return;
    }
    if (v is Map && v.length == 1 && v.keys.single == 'maltem') {
      _collect(context, v['maltem'], depth, out, key);
      return;
    }
    if (v is Map) {
      if (key != null) {
        out.add(
          Padding(
            padding: EdgeInsets.only(
              left: depth * 12.0 - 12,
              top: 12,
              bottom: 4,
            ),
            child: Text(
              label(key),
              style: text.titleSmall?.copyWith(color: t.accent),
            ),
          ),
        );
      }
      v.forEach((k, val) => _collect(context, val, depth + 1, out, '$k'));
      return;
    }
    if (v is List) {
      for (final (i, item) in v.indexed) {
        _collect(
          context,
          item,
          depth,
          out,
          item is Map && !item.containsKey('key')
              ? '${label(key ?? '')} ${i + 1}'
              : key,
        );
      }
      return;
    }
    out.add(
      Padding(
        padding: EdgeInsets.only(
          left: (depth - 1).clamp(0, 10) * 12.0,
          top: 3,
          bottom: 3,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 190,
              child: Text(label(key ?? ''), style: text.bodySmall),
            ),
            Expanded(
              child: SelectableText(
                value(v),
                style: text.bodyMedium?.copyWith(fontFeatures: tabular),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Runs [load] and shows its result in a dialog with a progress indicator.
Future<void> showInfoDialog(
  BuildContext context,
  String title,
  Future<dynamic> Function() load, {
  Widget Function(dynamic data)? builder,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: FutureBuilder(
          future: load(),
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Text(
                '${snap.error}',
                style: Theme.of(ctx).textTheme.bodyMedium
                    ?.copyWith(color: Tokens.of(ctx).danger),
              );
            }
            return SingleChildScrollView(
              child: builder != null
                  ? builder(snap.data)
                  : InfoView(data: snap.data),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Zavřít'),
        ),
      ],
    ),
  );
}
