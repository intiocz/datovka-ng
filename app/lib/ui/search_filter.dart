import 'package:flutter/material.dart';

import '../data/models.dart';
import 'app_scope.dart';
import 'format.dart';

/// Advanced search: date range, unread, with deadline, tag.
Future<void> showSearchFilter(BuildContext context) {
  final s = AppScope.of(context);
  var f = s.filter;
  return showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final text = Theme.of(ctx).textTheme;
        Future<DateTime?> pick(DateTime? initial) => showDatePicker(
          context: ctx,
          initialDate: initial ?? DateTime.now(),
          firstDate: DateTime(2009),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        SearchFilter copy({
          Object? from = _keep,
          Object? to = _keep,
          bool? unread,
          bool? deadline,
          Object? tag = _keep,
        }) => SearchFilter(
          from: from == _keep ? f.from : from as DateTime?,
          to: to == _keep ? f.to : to as DateTime?,
          unreadOnly: unread ?? f.unreadOnly,
          withDeadline: deadline ?? f.withDeadline,
          tag: tag == _keep ? f.tag : tag as String?,
        );
        return AlertDialog(
          title: const Text('Pokročilé hledání'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Doručeno', style: text.bodySmall),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        final d = await pick(f.from);
                        if (d != null) setState(() => f = copy(from: d));
                      },
                      child: Text(
                        f.from == null
                            ? 'od začátku'
                            : 'od ${dayDate(f.from!)}',
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final d = await pick(f.to);
                        if (d != null) setState(() => f = copy(to: d));
                      },
                      child: Text(
                        f.to == null ? 'do dneška' : 'do ${dayDate(f.to!)}',
                      ),
                    ),
                    if (f.from != null || f.to != null)
                      IconButton(
                        tooltip: 'Zrušit datum',
                        onPressed: () =>
                            setState(() => f = copy(from: null, to: null)),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                  ],
                ),
                CheckboxListTile(
                  value: f.unreadOnly,
                  onChanged: (v) =>
                      setState(() => f = copy(unread: v ?? false)),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Jen nepřečtené'),
                ),
                CheckboxListTile(
                  value: f.withDeadline,
                  onChanged: (v) =>
                      setState(() => f = copy(deadline: v ?? false)),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Jen se lhůtou'),
                ),
                if (s.allTags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Štítek', style: text.bodySmall),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in s.allTags)
                        ChoiceChip(
                          label: Text(t),
                          selected: f.tag == t,
                          onSelected: (on) =>
                              setState(() => f = copy(tag: on ? t : null)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                s.setFilter(const SearchFilter());
                Navigator.pop(ctx);
              },
              child: const Text('Zrušit filtry'),
            ),
            FilledButton(
              onPressed: () {
                s.setFilter(f);
                Navigator.pop(ctx);
              },
              child: const Text('Použít'),
            ),
          ],
        );
      },
    ),
  );
}

const _keep = Object();
