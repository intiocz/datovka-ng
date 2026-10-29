import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';

/// ISDS user privileges (bit flags of userPrivils).
const privileges = <int, String>{
  1: 'Číst zprávy (kromě do vlastních rukou)',
  2: 'Číst všechny zprávy',
  4: 'Odesílat zprávy',
  8: 'Seznamy zpráv a doručenky',
  16: 'Vyhledávat schránky',
  32: 'Spravovat schránku',
  64: 'Číst zprávy v datovém trezoru',
  128: 'Mazat zprávy v datovém trezoru',
};

const _types = {
  'PRIMARY_USER': 'Oprávněná osoba',
  'ENTRUSTED_USER': 'Pověřená osoba',
  'ADMINISTRATOR': 'Administrátor',
  'OFFICIAL': 'Systém',
  'OFFICIAL_CERT': 'Systém s certifikátem',
  'LIQUIDATOR': 'Likvidátor',
  'RECEIVER': 'Nucený správce',
  'GUARDIAN': 'Opatrovník',
};

/// Users of a data box: list, privileges, removing and adding entrusted persons.
class BoxUsersTab extends StatefulWidget {
  final DataBox box;

  const BoxUsersTab({super.key, required this.box});

  @override
  State<BoxUsersTab> createState() => _BoxUsersTabState();
}

class _BoxUsersTabState extends State<BoxUsersTab> {
  Future<List<Map<String, dynamic>>>? _users;

  void _load() {
    final s = AppScope.of(context);
    _users = s.op(widget.box, 'users').then((v) {
      final raw = (v as Map?)?['dbUsers'];
      final items = raw is Map ? raw['dbUserInfo'] : null;
      final list = items is List ? items : (items == null ? const [] : [items]);
      return [for (final u in list) (u as Map).cast<String, dynamic>()];
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_users == null) _load();
  }

  Future<void> _run(Future<void> Function() f) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await f();
      setState(_load);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<int?> _editPrivileges(int current) {
    var value = current;
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Oprávnění'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in privileges.entries)
                CheckboxListTile(
                  value: value & e.key != 0,
                  onChanged: (on) => setState(
                    () => value = on == true ? value | e.key : value & ~e.key,
                  ),
                  title: Text(e.value),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, value),
              child: const Text('Uložit'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add() async {
    final s = AppScope.of(context);
    final f = {
      for (final k in [
        'pnGivenNames',
        'pnLastName',
        'biDate',
        'adCity',
        'adStreet',
        'adNumberInMunicipality',
        'adNumberInStreet',
        'adZipCode',
      ])
        k: TextEditingController(),
    };
    const labels = {
      'pnGivenNames': 'Jméno',
      'pnLastName': 'Příjmení',
      'biDate': 'Datum narození (RRRR-MM-DD)',
      'adCity': 'Obec',
      'adStreet': 'Ulice',
      'adNumberInMunicipality': 'Číslo popisné',
      'adNumberInStreet': 'Číslo orientační',
      'adZipCode': 'PSČ',
    };
    var type = 'ENTRUSTED_USER';
    var privils = 1 | 2 | 4 | 8 | 16;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Přidat uživatele schránky'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in f.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: e.value,
                        decoration: InputDecoration(labelText: labels[e.key]),
                      ),
                    ),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: 'Role'),
                    items: const [
                      DropdownMenuItem(
                        value: 'ENTRUSTED_USER',
                        child: Text('Pověřená osoba'),
                      ),
                      DropdownMenuItem(
                        value: 'ADMINISTRATOR',
                        child: Text('Administrátor'),
                      ),
                    ],
                    onChanged: (v) => setState(() => type = v ?? type),
                  ),
                  TextButton(
                    onPressed: () async {
                      final v = await _editPrivileges(privils);
                      if (v != null) setState(() => privils = v);
                    },
                    child: const Text('Oprávnění…'),
                  ),
                  Text(
                    'ISDS pošle nové osobě přihlašovací údaje poštou.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Přidat'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final user = <String, Object?>{
      for (final e in f.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
      'adState': 'CZ',
      'userType': type,
      'userPrivils': privils,
    };
    await _run(() => s.op(widget.box, 'user_add', {'user': user}));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return FutureBuilder(
      future: _users,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('${snap.error}', style: TextStyle(color: t.danger)),
          );
        }
        final users = snap.data!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Přidat uživatele'),
              ),
            ),
            for (final u in users)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${u['pnGivenNames'] ?? ''} ${u['pnLastName'] ?? ''}'.trim(),
                ),
                subtitle: Text(
                  [
                    _types[u['userType']] ?? '${u['userType'] ?? ''}',
                    for (final e in privileges.entries)
                      if ((int.tryParse('${u['userPrivils']}') ?? 0) & e.key !=
                          0)
                        e.value,
                  ].join(' · '),
                  style: text.bodySmall,
                ),
                trailing: u['userType'] == 'PRIMARY_USER'
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Změnit oprávnění',
                            icon: const Icon(Icons.tune),
                            onPressed: () async {
                              final v = await _editPrivileges(
                                int.tryParse('${u['userPrivils']}') ?? 0,
                              );
                              if (v == null) return;
                              await _run(
                                () => s.op(widget.box, 'user_update', {
                                  'isds_id': '${u['isdsID']}',
                                  'user': {...u, 'userPrivils': v},
                                }),
                              );
                            },
                          ),
                          IconButton(
                            tooltip: 'Odebrat uživatele',
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text(
                                    'Odebrat uživatele ze schránky?',
                                  ),
                                  content: const Text(
                                    'Uživatel ztratí přístup do schránky.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Zrušit'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Odebrat'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                await _run(
                                  () => s.op(widget.box, 'user_delete', {
                                    'isds_id': '${u['isdsID']}',
                                  }),
                                );
                              }
                            },
                          ),
                        ],
                      ),
              ),
          ],
        );
      },
    );
  }
}
