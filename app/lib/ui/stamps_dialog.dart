import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'format.dart';

/// Messages whose qualified time stamp expires soon, with renewal in ISDS,
/// like the time stamp check of the original Datovka.
Future<void> showStamps(BuildContext context) {
  final s = AppScope.of(context);
  return showDialog(
    context: context,
    builder: (_) => AppScope(state: s, child: const _StampsDialog()),
  );
}

class _StampsDialog extends StatefulWidget {
  const _StampsDialog();

  @override
  State<_StampsDialog> createState() => _StampsDialogState();
}

class _StampsDialogState extends State<_StampsDialog> {
  static const _ranges = {
    90: 'do 3 měsíců',
    365: 'do roka',
    548: 'do roka a půl',
    1825: 'do 5 let',
  };
  var _days = 548;
  Future<List<StampExpiry>>? _list;
  final _renewing = <String>{};
  final _done = <String, String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list ??= AppScope.of(context).expiringStamps(_days);
  }

  void _load() =>
      setState(() => _list = AppScope.of(context).expiringStamps(_days));

  Future<void> _renew(StampExpiry e) async {
    final s = AppScope.of(context);
    setState(() => _renewing.add(e.dmId));
    try {
      final r = await s.op(e.box, 'resign', {'dm_id': e.dmId}) as Map?;
      final to = r?['valid_to'];
      _done[e.dmId] = to == null ? 'Obnoveno.' : 'Obnoveno, platí do $to.';
    } on Object catch (err) {
      _done[e.dmId] = '$err';
    }
    if (mounted) setState(() => _renewing.remove(e.dmId));
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Časová razítka'),
      content: SizedBox(
        width: 640,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Podepsaná zpráva je důkazem jen do konce platnosti svého '
              'časového razítka. ISDS ho obnoví v posledním roce a půl, '
              'potom už zprávu jako originál neprokážete.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Razítka, která vyprší', style: text.bodyMedium),
                DropdownButton<int>(
                  value: _days,
                  underline: const SizedBox(),
                  items: [
                    for (final e in _ranges.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _days = v;
                    _load();
                  },
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: FutureBuilder<List<StampExpiry>>(
                future: _list,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Text(
                      '${snap.error}',
                      style: text.bodyMedium?.copyWith(color: t.danger),
                    );
                  }
                  if (!snap.hasData) {
                    return Row(
                      children: [
                        const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Kontroluji razítka zpráv. Napoprvé to u velkého '
                            'archivu chvíli trvá, pak už je to hned.',
                            style: text.bodySmall,
                          ),
                        ),
                      ],
                    );
                  }
                  final list = snap.data!;
                  if (list.isEmpty) {
                    return Text(
                      'Žádné razítko v tomto období nevyprší.',
                      style: text.bodyMedium,
                    );
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: t.line),
                    itemBuilder: (context, i) => _row(context, list[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zavřít'),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, StampExpiry e) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final left = e.expires.difference(DateTime.now()).inDays;
    final expired = left < 0;
    final done = _done[e.dmId];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.subject.isEmpty ? 'Zpráva ${e.dmId}' : e.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '${e.received ? 'Od' : 'Pro'} ${e.counterparty} · ${e.box.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
                Text(
                  done ??
                      (expired
                          ? 'Razítko vypršelo ${dayDate(e.expires)}.'
                          : 'Razítko vyprší ${dayDate(e.expires)} (za $left dní).'),
                  style: text.bodySmall?.copyWith(
                    color: done != null
                        ? t.inkMuted
                        : expired || left < 90
                        ? t.danger
                        : t.warn,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (_renewing.contains(e.dmId))
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (!expired && done == null)
            Tooltip(
              message: e.renewable
                  ? 'ISDS k originálu přidá nové časové razítko.'
                  : 'Obnovit jde až v posledním roce a půl platnosti.',
              child: OutlinedButton(
                onPressed: e.renewable ? () => _renew(e) : null,
                child: const Text('Obnovit'),
              ),
            ),
        ],
      ),
    );
  }
}
