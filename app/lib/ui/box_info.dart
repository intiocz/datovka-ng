import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'box_users.dart';
import 'format.dart';
import 'info_view.dart';
import 'login_dialog.dart';

/// Information about a data box, loaded from ISDS on demand.
Future<void> showBoxInfo(BuildContext context, DataBox box) {
  final s = AppScope.of(context);
  return showDialog(
    context: context,
    builder: (_) => AppScope(
      state: s,
      child: _BoxInfo(box: box),
    ),
  );
}

class _BoxInfo extends StatelessWidget {
  final DataBox box;

  const _BoxInfo({required this.box});

  static const _tabs = [
    ('Schránka', 'owner_info'),
    ('Uživatel', 'user_info'),
    ('Kredit', 'credit'),
    ('Poštovní zprávy', 'pdz_info'),
    ('Datový trezor', 'dt_info'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final text = Theme.of(context).textTheme;
    final t = Tokens.of(context);
    return Dialog(
      child: SizedBox(
        width: 720,
        height: 560,
        child: DefaultTabController(
          length: _tabs.length + 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(box.name, style: text.headlineSmall),
                          Text(
                            '${box.kind}, ID ${box.isdsId ?? '?'}, uživatel ${box.username}, ${box.login.label}',
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zavřít',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (box.session != Session.active)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Row(
                    children: [
                      Icon(Icons.key_outlined, size: 16, color: t.warn),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Údaje z ISDS jsou dostupné po přihlášení.',
                        ),
                      ),
                      TextButton(
                        onPressed: () => showLoginDialog(context, box),
                        child: const Text('Přihlásit'),
                      ),
                    ],
                  ),
                ),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final (label, _) in _tabs) Tab(text: label),
                  const Tab(text: 'Uživatelé schránky'),
                  const Tab(text: 'Smazané zprávy'),
                  const Tab(text: 'Heslo'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final (_, op) in _tabs)
                      _OpTab(load: () => s.op(box, op)),
                    BoxUsersTab(box: box),
                    _ErasedTab(box: box),
                    _PasswordTab(box: box),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OpTab extends StatefulWidget {
  final Future<dynamic> Function() load;

  const _OpTab({required this.load});

  @override
  State<_OpTab> createState() => _OpTabState();
}

class _OpTabState extends State<_OpTab> with AutomaticKeepAliveClientMixin {
  late final Future<dynamic> _future = widget.load();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '${snap.error}',
              style: TextStyle(color: Tokens.of(context).danger),
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: InfoView(data: snap.data),
        );
      },
    );
  }
}

/// Messages ISDS deleted after 90 days, for a chosen month. ISDS prepares
/// the list asynchronously and only for months at least three months back.
class _ErasedTab extends StatefulWidget {
  final DataBox box;

  const _ErasedTab({required this.box});

  @override
  State<_ErasedTab> createState() => _ErasedTabState();
}

class _ErasedTabState extends State<_ErasedTab>
    with AutomaticKeepAliveClientMixin {
  static const _months = [
    'leden', 'únor', 'březen', 'duben', 'květen', 'červen',
    'červenec', 'srpen', 'září', 'říjen', 'listopad', 'prosinec',
  ];

  /// Months ISDS accepts, newest first: from three months back, two years.
  late final List<DateTime> _choices = [
    for (var i = 3; i < 27; i++)
      DateTime(DateTime.now().year, DateTime.now().month - i),
  ];
  late var _month = _choices.first;
  var _received = true;
  Future<dynamic>? _load;

  @override
  bool get wantKeepAlive => true;

  void _fetch() => setState(() {
    _load = AppScope.of(context).op(widget.box, 'erased', {
      'year': _month.year,
      'month': _month.month,
      'received': _received,
    });
  });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        Text(
          'ISDS maže zprávy 90 dní po doručení. Seznam smazaných zpráv připraví '
          'za jeden měsíc, nejpozději tři měsíce zpátky; příprava může trvat '
          'i desítky sekund.',
          style: text.bodySmall?.copyWith(color: t.inkMuted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<DateTime>(
              value: _month,
              items: [
                for (final m in _choices)
                  DropdownMenuItem(
                    value: m,
                    child: Text('${_months[m.month - 1]} ${m.year}'),
                  ),
              ],
              onChanged: (m) => setState(() => _month = m!),
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Přijaté')),
                ButtonSegment(value: false, label: Text('Odeslané')),
              ],
              selected: {_received},
              onSelectionChanged: (v) => setState(() => _received = v.first),
            ),
            FilledButton.tonal(onPressed: _fetch, child: const Text('Načíst')),
          ],
        ),
        const SizedBox(height: 16),
        if (_load != null)
          FutureBuilder(
            future: _load,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Text(
                  '${snap.error}',
                  style: TextStyle(color: t.danger),
                );
              }
              final list = (snap.data as List?) ?? const [];
              if (list.isEmpty) {
                return Text(
                  'V tomto měsíci ISDS žádné zprávy nesmazalo.',
                  style: text.bodySmall,
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Zpráv: ${list.length}', style: text.titleSmall),
                  for (final r in list.cast<Map>())
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('${r['annotation']}'),
                      subtitle: Text(
                        '${_received ? r['sender'] : r['recipient']} · '
                        'ID ${r['dm_id']} · doručeno ${_day('${r['delivery_time']}')}',
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  static String _day(String raw) {
    final d = DateTime.tryParse(raw);
    return d == null ? raw : dayDate(d.toLocal());
  }
}

class _PasswordTab extends StatefulWidget {
  final DataBox box;

  const _PasswordTab({required this.box});

  @override
  State<_PasswordTab> createState() => _PasswordTabState();
}

class _PasswordTabState extends State<_PasswordTab> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  Future<dynamic>? _expiry;
  String? _message;
  var _ok = false;
  var _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expiry ??= AppScope.of(context).op(widget.box, 'password_expiry');
  }

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _change(AppState s) async {
    if (_new.text != _again.text) {
      setState(() => _message = 'Nová hesla se neshodují.');
      return;
    }
    if (_new.text.length < 8) {
      setState(() => _message = 'Nové heslo musí mít aspoň 8 znaků.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await s.op(widget.box, 'change_password', {
        'old': _old.text,
        'new': _new.text,
      });
      setState(() {
        _ok = true;
        _message = 'Heslo bylo v ISDS změněno a uložené heslo v aplikaci je aktualizované.';
      });
    } on Object catch (e) {
      setState(() => _message = '$e');
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final text = Theme.of(context).textTheme;
    final t = Tokens.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder(
            future: _expiry,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return Text('Zjišťuji platnost hesla…', style: text.bodySmall);
              }
              if (snap.hasError) {
                return Text('${snap.error}', style: text.bodySmall);
              }
              final d = DateTime.tryParse('${snap.data}');
              if (d == null) {
                return Text(
                  'Heslo nemá omezenou platnost.',
                  style: text.bodyMedium,
                );
              }
              final left = daysUntil(d);
              return Text(
                'Heslo platí do ${dayDate(d.toLocal())} (${left >= 0 ? 'zbývá ${days(left)}' : 'vypršelo'}).',
                style: text.bodyMedium?.copyWith(
                  color: left < 14 ? t.warn : null,
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          Text('Změna hesla', style: text.titleMedium),
          const SizedBox(height: 10),
          SizedBox(
            width: 360,
            child: Column(
              children: [
                TextField(
                  controller: _old,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Současné heslo',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _new,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Nové heslo'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _again,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Nové heslo znovu',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _busy || widget.box.login == LoginMethod.mobileKey
                ? null
                : () => _change(s),
            child: const Text('Změnit heslo'),
          ),
          if (widget.box.login == LoginMethod.mobileKey)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Schránka se přihlašuje mobilním klíčem, heslo se mění na portálu ISDS.',
                style: text.bodySmall,
              ),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _message!,
                style: text.bodySmall?.copyWith(color: _ok ? t.ok : t.danger),
              ),
            ),
        ],
      ),
    );
  }
}
