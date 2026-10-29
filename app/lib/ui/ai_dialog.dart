import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/ai.dart';
import '../data/data_folder.dart';
import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'deadline.dart';
import 'format.dart';
import '../data/user_error.dart';

const _kinds = {
  'lhuta': 'Lhůta',
  'jednani': 'Jednání',
  'platba': 'Platba',
  'schuzka': 'Schůzka',
  'jine': 'Termín',
};

/// Analyses the attachments of [m] with Claude and offers the found dates for
/// the calendar and as the message deadline. Runs only when the user asks.
Future<void> showAiAnalysis(BuildContext context, Message m) {
  final s = AppScope.of(context);
  return showDialog(
    context: context,
    builder: (_) => AppScope(
      state: s,
      child: _AiDialog(m: m),
    ),
  );
}

class _AiDialog extends StatefulWidget {
  final Message m;

  const _AiDialog({required this.m});

  @override
  State<_AiDialog> createState() => _AiDialogState();
}

class _AiDialogState extends State<_AiDialog> {
  Future<AiResult>? _future;
  Future<AssistantNotice?>? _mode;
  Future<List<Attachment>>? _files;
  final _selected = <int>{};
  var _started = false;
  AiResult? _result;
  DateTime? _written;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.of(context);
    _mode ??= assistantNotice();
    _files ??= s.loadAttachments(widget.m);
  }

  void _start() {
    final core = AppScope.of(context).core;
    setState(() {
      _started = true;
      _future = core == null
          ? Future.error(
              UserError('AI asistent funguje jen v desktopové aplikaci.'),
            )
          : analyzeMessage(core, widget.m).then((r) {
              if (!mounted) return r;
              setState(() {
                _result = r;
                _selected.addAll(List.generate(r.events.length, (i) => i));
              });
              _keep(r);
              return r;
            });
    });
  }

  /// Writes the found deadline onto the message once. Later openings keep it.
  void _keep(AiResult r) {
    final when = rememberedDeadline(r);
    if (when == null || widget.m.deadline != null) return;
    AppScope.of(context).setDeadline(widget.m.dmId, when);
    _written = when;
  }

  Future<void> _calendar(AiResult r, {required bool save}) async {
    final events = [for (final i in _selected.toList()..sort()) r.events[i]];
    if (events.isEmpty) return;
    final ics = buildIcs(widget.m, events);
    final messenger = ScaffoldMessenger.of(context);
    final core = AppScope.of(context).core;
    if (save) {
      final loc = await getSaveLocation(
        suggestedName: 'DZ_${widget.m.dmId}.ics',
      );
      if (loc == null) return;
      await File(loc.path).writeAsString(ics);
      messenger.showSnackBar(SnackBar(content: Text('Uloženo: ${loc.path}')));
    } else if (Platform.isIOS) {
      final added = await DataFolder.addToCalendar(
        calendarEntries(widget.m, events),
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            added < 0
                ? 'Kalendář není povolený. Povolte ho v Nastavení → Datovka → Kalendáře.'
                : 'Přidáno do kalendáře: $added',
          ),
        ),
      );
    } else {
      // Opening an .ics file lets the system calendar import it.
      final path = '${Directory.systemTemp.path}/DZ_${widget.m.dmId}.ics';
      await File(path).writeAsString(ics);
      await core?.openFile(path);
    }
  }

  bool get _canWrite => _result != null && _selected.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Rozbor příloh'),
      content: SizedBox(
        width: 600,
        child: !_started
            ? _Consent(mode: _mode!, files: _files!, onStart: _start)
            : FutureBuilder<AiResult>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return SizedBox(
                height: 120,
                child: Row(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Text(
                        'Claude čte přílohy a hledá termíny. U delších dokumentů to může trvat i minutu.',
                        style: text.bodyMedium,
                      ),
                    ),
                  ],
                ),
              );
            }
            if (snap.hasError) {
              return Text(
                '${snap.error}',
                style: text.bodyMedium?.copyWith(color: t.danger),
              );
            }
            final r = snap.data!;
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.summary, style: text.bodyMedium),
                  if (_written != null || widget.m.deadline != null) ...[
                    const SizedBox(height: 14),
                    Text('Lhůta je zapsaná u zprávy', style: text.titleMedium),
                    const SizedBox(height: 8),
                    DeadlineBar(
                      start: widget.m.delivered,
                      end: _written ?? widget.m.deadline!,
                      height: 6,
                    ),
                  ] else if (r.suggestedDeadline != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Navržená lhůta: ${dayDate(r.suggestedDeadline!)}',
                      style: text.titleMedium,
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (r.events.isEmpty)
                    Text(
                      'V přílohách nejsou žádné termíny.',
                      style: text.bodySmall,
                    )
                  else
                    for (final (i, e) in r.events.indexed)
                      CheckboxListTile(
                        value: _selected.contains(i),
                        onChanged: (v) => setState(
                          () => v == true
                              ? _selected.add(i)
                              : _selected.remove(i),
                        ),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          '${_kinds[e.kind] ?? 'Termín'}: ${e.title}',
                          style: text.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          [
                            '${dayDate(e.date)}${e.time.isEmpty ? '' : ' ${e.time}'}${e.location.isEmpty ? '' : ', ${e.location}'}',
                            if (e.kind == 'lhuta' || e.kind == 'platba')
                              'Do kalendáře o den dřív: ${dayDate(e.date.subtract(const Duration(days: 1)))}',
                            if (e.description.isNotEmpty) e.description,
                            if (e.source.isNotEmpty) '„${e.source}“',
                          ].join('\n'),
                          style: text.bodySmall,
                        ),
                      ),
                  const SizedBox(height: 8),
                  Text(
                    'Termíny určil AI asistent. Před spoléháním na ně je ověřte v dokumentu.',
                    style: text.bodySmall?.copyWith(color: t.inkMuted),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zavřít'),
        ),
        if (AiSettings.desktop)
          TextButton(
            onPressed: _canWrite ? () => _calendar(_result!, save: true) : null,
            child: const Text('Uložit ICS…'),
          ),
        FilledButton.icon(
          onPressed: _canWrite ? () => _calendar(_result!, save: false) : null,
          icon: const Icon(Icons.event, size: 18),
          label: const Text('Přidat do kalendáře'),
        ),
      ],
    );
  }
}

/// Says where the attachment text goes before anything is read.
class _Consent extends StatelessWidget {
  final Future<AssistantNotice?> mode;
  final Future<List<Attachment>> files;
  final VoidCallback onStart;

  const _Consent({
    required this.mode,
    required this.files,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return FutureBuilder(
      future: Future.wait<Object?>([mode, files]),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            '${snap.error}',
            style: text.bodyMedium?.copyWith(color: t.danger),
          );
        }
        if (!snap.hasData) {
          return const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final how = snap.data![0] as AssistantNotice?;
        final atts = snap.data![1] as List<Attachment>;
        if (how == null) {
          return Text(
            'Asistent je vypnutý. Připojení zvolíte v nastavení asistenta.',
            style: text.bodyMedium?.copyWith(color: t.danger),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(how.text, style: text.bodyMedium),
            const SizedBox(height: 12),
            Text('Co se pošle ke čtení', style: text.titleMedium),
            const SizedBox(height: 6),
            if (atts.isEmpty)
              Text('Zpráva nemá přílohy.', style: text.bodySmall)
            else
              for (final a in atts)
                Text('• ${a.name}', style: text.bodySmall),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: atts.isEmpty ? null : onStart,
                child: Text(how.button),
              ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> showAiSettings(BuildContext context) async {
  final key = TextEditingController();
  final hasKey = await AiSettings.apiKey() != null;
  final cli = await AiSettings.claudeCli();
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (ctx) {
      final text = Theme.of(ctx).textTheme;
      return AlertDialog(
        title: const Text('AI asistent'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Asistent na vyžádání přečte přílohy zprávy, najde lhůty a termíny a připraví '
                'je do kalendáře. Text příloh může opustit tento počítač.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text('Claude Code (vaše předplatné)', style: text.titleMedium),
              Text(
                cli == null
                    ? 'Nenalezen. Když je nainstalovaný, text příloh může opustit tento počítač.'
                    : 'Nalezen: $cli. Text příloh může opustit tento počítač.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 16),
              Text('API klíč', style: text.titleMedium),
              Text(
                hasKey ? 'Klíč je uložený v Klíčence.' : 'Klíč není zadaný.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: key,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Nový API klíč (sk-ant-…)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (hasKey)
            TextButton(
              onPressed: () async {
                await AiSettings.deleteApiKey();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Smazat klíč'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Zavřít'),
          ),
          FilledButton(
            onPressed: () async {
              if (key.text.trim().isEmpty) return;
              await AiSettings.setApiKey(key.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Uložit klíč'),
          ),
        ],
      );
    },
  );
}
