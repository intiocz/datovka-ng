import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'compose.dart';

/// Search in the public ISDS directory of data boxes.
class DirectoryView extends StatelessWidget {
  final Widget? leading;

  const DirectoryView({super.key, this.leading});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final results = s.directoryResults;
    final contacts = s.contactsMatching(s.directoryQuery);

    return Material(
      color: t.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 4)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Adresář schránek', style: text.headlineSmall),
                        Text(
                          'Veřejný seznam všech datových schránek v ISDS',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<DirectoryScope>(
                        showSelectedIcon: false,
                        segments: [
                          for (final sc in DirectoryScope.values)
                            ButtonSegment(value: sc, label: Text(sc.label)),
                        ],
                        selected: {s.directoryScope},
                        onSelectionChanged: (v) {
                          s.setDirectoryScope(v.first);
                          s.searchDirectory(s.directoryQuery);
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        autofocus: true,
                        onChanged: s.searchDirectory,
                        style: text.bodyMedium,
                        keyboardType: s.directoryScope == DirectoryScope.ico
                            ? TextInputType.number
                            : TextInputType.text,
                        decoration: InputDecoration(
                          hintText: switch (s.directoryScope) {
                            DirectoryScope.general =>
                              'Např. finanční úřad Praha',
                            DirectoryScope.ico => 'Osmimístné IČO',
                            DirectoryScope.boxId =>
                              'Sedmiznakové ID, např. 4h6aibd',
                          },
                          hintStyle: text.bodyMedium?.copyWith(
                            color: t.inkMuted,
                          ),
                          prefixIcon: Icon(
                            Icons.search,
                            size: 20,
                            color: t.inkMuted,
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 40,
                          ),
                          suffixIcon: s.directoryBusy
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: t.accent,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                      CheckboxListTile(
                        value: s.authoritiesOnly,
                        onChanged: (v) => s.setAuthoritiesOnly(v ?? false),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          'Jen orgány veřejné moci',
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: t.line),
            Expanded(
              child: ListView(
                children: [
                  if (contacts.isNotEmpty) ...[
                    _Section(
                      s.directoryQuery.isEmpty
                          ? 'Moje kontakty (${contacts.length})'
                          : 'Moje kontakty',
                    ),
                    for (final c in contacts.take(
                      s.directoryQuery.isEmpty ? contacts.length : 20,
                    )) ...[
                      _ContactEntry(c: c),
                      Divider(height: 1, indent: 20, color: t.line),
                    ],
                  ],
                  if (s.directoryQuery.isNotEmpty) ...[
                    const _Section('Všechny schránky v ISDS'),
                    if (results == null)
                      const _Hint(
                        text: 'Zadejte aspoň 3 znaky. Hledání probíhá přímo v ISDS.',
                      )
                    else if (results.isEmpty)
                      const _Hint(
                        text: 'Žádná schránka neodpovídá. Zkuste kratší výraz nebo hledání podle IČO.',
                      )
                    else
                      for (final e in results) ...[
                        _Entry(e: e),
                        Divider(height: 1, indent: 20, color: t.line),
                      ],
                  ] else if (contacts.isEmpty)
                    const _Hint(
                      text: 'Zadejte název, IČO nebo ID schránky. Hledání probíhá přímo v ISDS.',
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  final DirectoryEntry e;

  const _Entry({required this.e});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final facts = [
      'ID ${e.boxId}',
      if (e.ico != null) 'IČO ${e.ico}',
      e.type,
      if (e.acceptsCommercial) 'přijímá poštovní datové zprávy',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(e.address, style: text.bodySmall?.copyWith(color: t.ink)),
                const SizedBox(height: 4),
                Text(
                  facts.join(', '),
                  style: text.bodySmall?.copyWith(fontFeatures: tabular),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Zkopírovat ID schránky',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: e.boxId));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('ID ${e.boxId} zkopírováno'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            icon: Icon(Icons.copy_outlined, size: 18, color: t.inkMuted),
          ),
          TextButton(
            onPressed: () => showCompose(context, Draft.to(e.boxId, e.name)),
            child: const Text('Napsat zprávu'),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;

  const _Hint({required this.text});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  final String label;

  const _Section(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// A correspondent from the user's own messages.
class _ContactEntry extends StatelessWidget {
  final Contact c;

  const _ContactEntry({required this.c});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final n = c.count;
    final msgs = n == 1 ? 'zpráva' : (n >= 2 && n <= 4 ? 'zprávy' : 'zpráv');
    final facts = [
      'ID ${c.boxId}',
      '$n $msgs',
      'naposledy ${c.last.day}. ${c.last.month}. ${c.last.year}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => AppScope.of(context).messagesWith(c),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (c.address.isNotEmpty)
                    Text(
                      c.address,
                      style: text.bodySmall?.copyWith(color: t.ink),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    facts.join(', '),
                    style: text.bodySmall?.copyWith(fontFeatures: tabular),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zkopírovat ID schránky',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: c.boxId));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('ID ${c.boxId} zkopírováno'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            icon: Icon(Icons.copy_outlined, size: 18, color: t.inkMuted),
          ),
          TextButton(
            onPressed: () => showCompose(context, Draft.to(c.boxId, c.name)),
            child: const Text('Napsat zprávu'),
          ),
        ],
      ),
    );
  }
}
