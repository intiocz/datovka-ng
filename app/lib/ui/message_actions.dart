import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../data/user_error.dart';
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
  template,
  email,
  emailZfo,
  emailAttachments,
  records,
  resign,
  redownload,
  erase,
  deleteLocal,
  saveZfo,
  saveAttachments,
  openZfo,
  openDelivery,
  deadline,
  tag,
}

/// "More" menu of a message in its detail: the same actions as the right
/// click in the list, except opening it.
class MessageActions extends StatelessWidget {
  final Message m;

  const MessageActions({super.key, required this.m});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return MenuAnchor(
      menuChildren: _menu(context, m),
      builder: (context, menu, _) => IconButton(
        tooltip: 'Další akce',
        icon: Icon(Icons.more_horiz, color: t.inkMuted),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

/// Everything that can be done with one message, grouped like the menu of
/// the original Datovka.
List<Widget> _menu(BuildContext context, Message m, {bool inList = false}) {
  final s = AppScope.of(context);
  final received = m.direction == Direction.received;
  final phone = Platform.isIOS || Platform.isAndroid;
  void run(_Action a) => _runAction(context, m, a);
  Widget item(String label, VoidCallback onPressed, {Widget? trailing}) =>
      MenuItemButton(
        onPressed: onPressed,
        trailingIcon: trailing,
        child: Text(label),
      );
  Widget sub(String label, List<Widget> children) =>
      SubmenuButton(menuChildren: children, child: Text(label));
  const line = Divider(height: 1);

  return [
    if (inList) item('Otevřít', () => s.open(m.dmId)),
    if (received)
      item('Odpovědět', () => showCompose(context, Draft.reply(m))),
    item('Přeposlat', () => run(_Action.forward)),
    item('Použít jako šablonu', () => run(_Action.template)),
    line,
    sub('Označit', [
      if (received)
        item(
          m.isRead ? 'Jako nepřečtené' : 'Jako přečtené',
          () => s.toggleRead(m.dmId),
        ),
      if (received) line,
      for (final st in ProcessState.values)
        item(
          st.label,
          () => s.setProcessState(m, st),
          trailing: m.processState == st
              ? const Icon(Icons.check, size: 16)
              : null,
        ),
    ]),
    item('Lhůta…', () => run(_Action.deadline)),
    item('Štítek…', () => run(_Action.tag)),
    item(
      m.note == null ? 'Poznámka…' : 'Upravit poznámku…',
      () => editNote(context, m),
    ),
    item('Najít termíny (AI)', () => showAiAnalysis(context, m)),
    line,
    sub('Uložit', [
      item('Podepsanou zprávu (ZFO)…', () => run(_Action.saveZfo)),
      item('Doručenku (ZFO)…', () => run(_Action.saveDelivery)),
      item(
        'Obálku do PDF…',
        () => saveMessagePdf(context, m, MessagePdf.envelope),
      ),
      item(
        'Doručenku do PDF…',
        () => saveMessagePdf(context, m, MessagePdf.delivery),
      ),
      if (!phone)
        item('Všechny přílohy…', () => run(_Action.saveAttachments)),
    ]),
    if (!phone) item('Tisk obálky…', () => printEnvelope(context, m)),
    sub('Otevřít v jiné aplikaci', [
      item('Zprávu (ZFO)', () => run(_Action.openZfo)),
      item('Doručenku (ZFO)', () => run(_Action.openDelivery)),
    ]),
    if (!phone)
      sub('Poslat e-mailem', [
        item('Podepsanou zprávu (ZFO)', () => run(_Action.emailZfo)),
        item('Přílohy', () => run(_Action.emailAttachments)),
        item('Zprávu i přílohy', () => run(_Action.email)),
      ]),
    item('Uložit do spisové služby…', () => run(_Action.records)),
    line,
    sub('ISDS', [
      item('Ověřit zprávu v ISDS', () => run(_Action.verify)),
      item('Kdo zprávu odeslal', () => run(_Action.author)),
      item('Doručenka a události', () => run(_Action.delivery)),
      item('Obnovit časové razítko', () => run(_Action.resign)),
      item('Stáhnout znovu z ISDS', () => run(_Action.redownload)),
    ]),
    line,
    item('Smazat jen v počítači…', () => run(_Action.deleteLocal)),
    item('Smazat v ISDS…', () => run(_Action.erase)),
  ];
}

/// Saves a signed file of the message where the user picks; on a phone it
/// opens in the preview, where it can be shared or saved.
Future<void> saveSignedFile(
  BuildContext context,
  Message m, {
  bool delivery = false,
}) async {
  final s = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final name = '${delivery ? 'DD' : 'DZ'}_${m.dmId}.zfo';
  final temp = s.tempPath(name);
  if (temp == null) return;
  try {
    _writeSigned(s, m, temp, delivery: delivery);
    if (Platform.isIOS || Platform.isAndroid) {
      await s.core?.openFile(temp);
      return;
    }
    final loc = await getSaveLocation(suggestedName: name);
    if (loc == null) return;
    await File(temp).copy(loc.path);
    messenger.showSnackBar(SnackBar(content: Text('Uloženo: ${loc.path}')));
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

void _writeSigned(
  AppState s,
  Message m,
  String path, {
  required bool delivery,
}) {
  final box = s.boxById(m.boxId);
  if (box == null) throw UserError('Schránka zprávy tu není.');
  if (delivery) {
    s.localOp(box, 'save_delivery_zfo', {'dm_id': m.dmId, 'path': path});
  } else {
    s.core?.call('save_zfo', ['', m.boxId, int.parse(m.dmId), path]);
  }
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
                    ? 'ISDS potvrdil, že uložený originál je pravý a nezměněný.'
                    : 'ISDS uložený originál NEPOTVRDIL. Soubor není pravý nebo byl změněn.',
                style: text.titleMedium?.copyWith(color: ok ? t.ok : t.danger),
              ),
              const SizedBox(height: 12),
              InfoView(
                data: {
                  'Služba ISDS': d['method'],
                  'Algoritmus otisku': d['algorithm'],
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
      await saveSignedFile(context, m, delivery: true);
    case _Action.saveZfo:
      await saveSignedFile(context, m);
    case _Action.openZfo || _Action.openDelivery:
      final delivery = a == _Action.openDelivery;
      final path = s.tempPath('${delivery ? 'DD' : 'DZ'}_${m.dmId}.zfo');
      if (path == null) return;
      try {
        _writeSigned(s, m, path, delivery: delivery);
        await s.core?.openFile(path);
      } on Object catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
    case _Action.saveAttachments:
      final atts = await s.loadAttachments(m);
      if (atts.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Zpráva nemá přílohy.')),
        );
        return;
      }
      final dir = await getDirectoryPath(confirmButtonText: 'Uložit sem');
      if (dir == null) return;
      var saved = 0;
      for (final att in atts) {
        final from = s.attachmentFile(m, att);
        if (from == null) continue;
        await File(from).copy('$dir${Platform.pathSeparator}${att.name}');
        saved++;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Uloženo příloh: $saved do $dir')),
      );
    case _Action.template:
      // Same recipient, subject, references and files, as a new message.
      final files = [
        for (final att in await s.loadAttachments(m)) ?s.attachmentFile(m, att),
      ];
      if (!context.mounted) return;
      await showCompose(
        context,
        Draft(
          fromBoxId: m.boxId,
          recipients: [
            if (m.counterpartyBoxId != null)
              (boxId: m.counterpartyBoxId!, name: m.counterparty),
          ],
          subject: m.subject,
          senderRef: m.direction == Direction.sent ? m.ourRef : null,
          recipientRef: m.direction == Direction.sent ? m.theirRef : null,
          files: files,
        ),
      );
    case _Action.deadline:
      final d = await showDatePicker(
        context: context,
        initialDate: m.deadline ?? DateTime.now().add(const Duration(days: 15)),
        firstDate: DateTime.now().subtract(const Duration(days: 365)),
        lastDate: DateTime.now().add(const Duration(days: 730)),
        helpText: 'Lhůta pro reakci',
      );
      if (d != null) s.setDeadline(m.dmId, d);
    case _Action.tag:
      final tag = await _askTag(context, m);
      if (tag != null && tag.trim().isNotEmpty) s.setTag(m, tag.trim(), true);
    case _Action.redownload:
      try {
        await s.redownload(m);
        messenger.showSnackBar(
          const SnackBar(content: Text('Zpráva je znovu stažená z ISDS.')),
        );
      } on Object catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Zprávu se nepodařilo stáhnout: $e')),
        );
      }
    case _Action.deleteLocal:
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Smazat zprávu jen v počítači?'),
          content: Text(
            'Zpráva i podepsaný originál zmizí z tohoto archivu, a tím ze všech '
            'zařízení, která ho sdílejí. V ISDS zůstane, dokud ji ISDS samo '
            'nesmaže (${dayDate(m.isdsDeletion)}), a do té doby jde znovu stáhnout.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Smazat v počítači'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        s.deleteLocal(m);
      } on Object catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Smazání selhalo: $e')));
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
    case _Action.email || _Action.emailZfo || _Action.emailAttachments:
      // The signed original and/or the attachments go into a new e-mail.
      final zfo = a == _Action.emailAttachments ? null : await s.saveZfo(m);
      final files = <String>[
        ?zfo,
        if (a != _Action.emailZfo)
          for (final att in await s.loadAttachments(m))
            ?s.attachmentFile(m, att),
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

/// Right-click (or long-press) menu of a message in the list, at [pos].
Future<void> showMessageMenu(BuildContext context, Offset pos, Message m) {
  final overlay = Overlay.of(context);
  final box = overlay.context.findRenderObject() as RenderBox;
  final at = box.globalToLocal(pos);
  final controller = MenuController();
  final done = Completer<void>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: at.dx,
      top: at.dy,
      child: MenuAnchor(
        controller: controller,
        onClose: () {
          // Let a chosen item run before the anchor goes away.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (entry.mounted) entry.remove();
            if (!done.isCompleted) done.complete();
          });
        },
        menuChildren: _menu(context, m, inList: true),
        child: const SizedBox.shrink(),
      ),
    ),
  );
  overlay.insert(entry);
  WidgetsBinding.instance.addPostFrameCallback((_) => controller.open());
  return done.future;
}

Future<String?> _askTag(BuildContext context, Message m) {
  final s = AppScope.of(context);
  final c = TextEditingController();
  return showDialog<String>(
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
                ActionChip(label: Text(t), onPressed: () => Navigator.pop(ctx, t)),
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
}
