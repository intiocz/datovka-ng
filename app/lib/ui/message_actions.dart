import 'dart:io';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'ai_dialog.dart';
import 'compose.dart';
import 'envelope_pdf.dart';
import 'format.dart';
import 'info_view.dart';
import 'records_dialog.dart';

enum _Action {
  verify,
  author,
  delivery,
  saveDelivery,
  forward,
  email,
  records,
  resign,
  erase,
}

/// "More" menu of a message: ISDS checks, delivery info, forwarding, erasing.
class MessageActions extends StatelessWidget {
  final Message m;

  const MessageActions({super.key, required this.m});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return PopupMenuButton<_Action>(
      tooltip: 'Další akce',
      icon: Icon(Icons.more_horiz, color: t.inkMuted),
      onSelected: (a) => _run(context, a),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: _Action.verify,
          child: Text('Ověřit zprávu v ISDS'),
        ),
        PopupMenuItem(value: _Action.author, child: Text('Kdo zprávu odeslal')),
        PopupMenuItem(
          value: _Action.delivery,
          child: Text('Doručenka a události'),
        ),
        PopupMenuItem(
          value: _Action.saveDelivery,
          child: Text('Uložit doručenku (ZFO)'),
        ),
        PopupMenuDivider(),
        PopupMenuItem(value: _Action.forward, child: Text('Přeposlat')),
        PopupMenuItem(value: _Action.email, child: Text('Poslat e-mailem')),
        PopupMenuItem(
          value: _Action.records,
          child: Text('Uložit do spisové služby…'),
        ),
        PopupMenuDivider(),
        PopupMenuItem(value: _Action.erase, child: Text('Smazat v ISDS…')),
      ],
    );
  }

  Future<void> _run(BuildContext context, _Action a) =>
      _runAction(context, m, a);
}

Future<void> _runAction(BuildContext context, Message m, _Action a) async {
  final s = AppScope.of(context);
  final box = s.boxById(m.boxId);
  if (box == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final args = {'dm_id': m.dmId};
  switch (a) {
    case _Action.verify:
      await showInfoDialog(
        context,
        'Ověření zprávy v ISDS',
        () => s.op(box, 'verify', args),
        builder: (d) {
          final ok = d['match'] == true;
          final text = Theme.of(context).textTheme;
          final t = Tokens.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ok
                    ? 'Uložený originál odpovídá zprávě v ISDS.'
                    : 'Uložený originál se liší od zprávy v ISDS!',
                style: text.titleMedium?.copyWith(color: ok ? t.ok : t.danger),
              ),
              const SizedBox(height: 12),
              InfoView(
                data: {
                  'Algoritmus': d['algorithm'],
                  'Otisk v ISDS': d['isds_hash'],
                  'Otisk originálu': d['local_hash'],
                },
              ),
            ],
          );
        },
      );
    case _Action.author:
      await showInfoDialog(
        context,
        'Kdo zprávu odeslal',
        () => s.op(box, 'author', args),
        builder: (d) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InfoView(data: d),
            const SizedBox(height: 16),
            Text(
              'Jméno a další údaje ISDS ukáže jen tehdy, když je odesílatel '
              'při odeslání zveřejnil. Jinak je známá jen jeho role ve schránce.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    case _Action.delivery:
      await showInfoDialog(
        context,
        'Doručenka a události',
        () async => s.localOp(box, 'delivery_events', args),
        builder: (d) {
          final events = (d as List?) ?? const [];
          final text = Theme.of(context).textTheme;
          if (events.isEmpty) {
            return Text('Doručenka zatím není stažená.', style: text.bodySmall);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(
                          _time('${e['time']}'),
                          style: text.bodySmall?.copyWith(
                            fontFeatures: tabular,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${e['description']}',
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      );
    case _Action.saveDelivery:
      try {
        final path = s.tempPath('DD_${m.dmId}.zfo')!;
        s.localOp(box, 'save_delivery_zfo', {...args, 'path': path});
        messenger.showSnackBar(
          SnackBar(content: Text('Doručenka uložena: $path')),
        );
      } on Object catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
    case _Action.forward:
      final zfo = await s.saveZfo(m);
      if (zfo == null || !context.mounted) return;
      await showCompose(
        context,
        Draft(
          fromBoxId: m.boxId,
          subject: m.subject.startsWith('Fwd: ')
              ? m.subject
              : 'Fwd: ${m.subject}',
          files: [zfo],
        ),
      );
    case _Action.email:
      // The signed original and the attachments go into a new e-mail.
      final files = <String>[
        ?await s.saveZfo(m),
        for (final a in await s.loadAttachments(m)) ?s.attachmentFile(m, a),
      ];
      if (files.isEmpty) return;
      if (Platform.isMacOS) {
        await Process.run('open', ['-a', 'Mail', ...files]);
      } else {
        await s.core?.openFile(File(files.first).parent.path);
      }
    case _Action.records:
      await showRecordsUpload(context, m);
    case _Action.resign:
      try {
        final r = await s.op(box, 'resign', args) as Map?;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Časové razítko obnoveno${r?['valid_to'] == null ? '' : ', platí do ${r!['valid_to']}'}.',
            ),
          ),
        );
      } on Object catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Obnova razítka selhala: $e')),
        );
      }
    case _Action.erase:
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Smazat zprávu v ISDS?'),
          content: const Text(
            'Zpráva se smaže v ISDS. Podepsaný originál v tomto archivu zůstane. '
            'Akci nelze vrátit.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Smazat v ISDS'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await s.op(box, 'erase', {
          ...args,
          'incoming': m.direction == Direction.received,
        });
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Zpráva smazána v ISDS, originál zůstal v archivu.'),
          ),
        );
      } on Object catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Smazání selhalo: $e')));
      }
  }
}

/// Edits the note of [m]; an emptied text removes it.
Future<void> editNote(BuildContext context, Message m) async {
  final s = AppScope.of(context);
  final c = TextEditingController(text: m.note ?? '');
  final saved = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Poznámka ke zprávě'),
      content: SizedBox(
        width: 460,
        child: TextField(
          controller: c,
          autofocus: true,
          minLines: 4,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: 'Např. komu jsme zprávu předali, co je domluveno…',
            helperText: 'Poznámku uvidí i původní Datovka. Smazáním textu ji odeberete.',
            helperMaxLines: 2,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, c.text),
          child: const Text('Uložit'),
        ),
      ],
    ),
  );
  c.dispose();
  if (saved != null) s.setNote(m, saved);
}

String _time(String raw) {
  final t = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  return t == null ? raw : longDate(t.toLocal());
}

/// Right-click (or long-press) menu of a message in the list.
Future<void> showMessageMenu(
  BuildContext context,
  Offset pos,
  Message m,
) async {
  final s = AppScope.of(context);
  final received = m.direction == Direction.received;
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: [
      const PopupMenuItem(value: 'open', child: Text('Otevřít')),
      if (received)
        PopupMenuItem(
          value: 'read',
          child: Text(
            m.isRead ? 'Označit jako nepřečtené' : 'Označit jako přečtené',
          ),
        ),
      const PopupMenuDivider(),
      if (received)
        const PopupMenuItem(value: 'reply', child: Text('Odpovědět')),
      const PopupMenuItem(value: 'forward', child: Text('Přeposlat')),
      const PopupMenuItem(value: 'email', child: Text('Poslat e-mailem')),
      const PopupMenuItem(
        value: 'records',
        child: Text('Uložit do spisové služby…'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'zfo',
        child: Text('Uložit podepsanou zprávu (ZFO)'),
      ),
      const PopupMenuItem(value: 'print', child: Text('Obálka do PDF / tisk')),
      const PopupMenuItem(
        value: 'delivery',
        child: Text('Doručenka a události'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'deadline', child: Text('Nastavit lhůtu…')),
      const PopupMenuItem(value: 'tag', child: Text('Přidat štítek…')),
      const PopupMenuItem(value: 'ai', child: Text('Najít termíny (AI)')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'verify', child: Text('Ověřit zprávu v ISDS')),
      const PopupMenuItem(value: 'author', child: Text('Kdo zprávu odeslal')),
      const PopupMenuItem(
        value: 'resign',
        child: Text('Obnovit časové razítko'),
      ),
      const PopupMenuItem(value: 'erase', child: Text('Smazat v ISDS…')),
    ],
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'open':
      s.open(m.dmId);
    case 'read':
      s.toggleRead(m.dmId);
    case 'reply':
      await showCompose(context, Draft.reply(m));
    case 'zfo':
      final path = await s.saveZfo(m);
      if (path != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Uloženo: $path')));
      }
    case 'print':
      await printEnvelope(context, m);
    case 'deadline':
      final d = await showDatePicker(
        context: context,
        initialDate: m.deadline ?? DateTime.now().add(const Duration(days: 15)),
        firstDate: DateTime.now().subtract(const Duration(days: 365)),
        lastDate: DateTime.now().add(const Duration(days: 730)),
        helpText: 'Lhůta pro reakci',
      );
      if (d != null) s.setDeadline(m.dmId, d);
    case 'tag':
      final c = TextEditingController();
      final tag = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Přidat štítek'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Název štítku'),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final t in s.allTags.where((t) => !m.tags.contains(t)))
                    ActionChip(
                      label: Text(t),
                      onPressed: () => Navigator.pop(ctx, t),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Přidat'),
            ),
          ],
        ),
      );
      if (tag != null && tag.trim().isNotEmpty) s.setTag(m, tag.trim(), true);
    case 'ai':
      await showAiAnalysis(context, m);
    case 'forward':
      await _runAction(context, m, _Action.forward);
    case 'email':
      await _runAction(context, m, _Action.email);
    case 'records':
      await _runAction(context, m, _Action.records);
    case 'delivery':
      await _runAction(context, m, _Action.delivery);
    case 'verify':
      await _runAction(context, m, _Action.verify);
    case 'author':
      await _runAction(context, m, _Action.author);
    case 'resign':
      await _runAction(context, m, _Action.resign);
    case 'erase':
      await _runAction(context, m, _Action.erase);
  }
}
