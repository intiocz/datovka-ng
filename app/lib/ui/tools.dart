import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_scope.dart';
import 'connect_assistant.dart';
import 'help_view.dart';
import 'gov_services_dialog.dart';
import 'records_dialog.dart';
import 'settings_dialog.dart';
import 'signature_view.dart';

enum _Tool {
  verifyLocal,
  authenticate,
  import,
  mobile,
  overview,
  govServices,
  backup,
  restore,
  ai,
  help,
  records,
  settings,
}

/// Less frequent actions: verifying and importing ZFO files, backups.
class ToolsMenu extends StatelessWidget {
  /// What opens the menu; three dots when not given.
  final Widget? child;

  const ToolsMenu({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return PopupMenuButton<_Tool>(
      tooltip: 'Nástroje',
      icon: child == null
          ? Icon(Icons.more_vert, size: 20, color: t.inkMuted)
          : null,
      position: PopupMenuPosition.under,
      child: child,
      onSelected: (a) => _run(context, a),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: _Tool.authenticate,
          child: Text('Ověřit soubor ZFO v ISDS…'),
        ),
        PopupMenuItem(
          value: _Tool.import,
          child: Text('Importovat zprávy ZFO…'),
        ),
        PopupMenuItem(
          value: _Tool.overview,
          child: Text('Přehled korespondence (CSV)…'),
        ),
        PopupMenuItem(
          value: _Tool.govServices,
          child: Text('Elektronická podání (Czech POINT)…'),
        ),
        PopupMenuDivider(),
        PopupMenuItem(value: _Tool.backup, child: Text('Zálohovat data…')),
        PopupMenuItem(value: _Tool.restore, child: Text('Obnovit ze zálohy…')),
        PopupMenuDivider(),
        PopupMenuItem(value: _Tool.ai, child: Text('Připojit asistenta…')),
        PopupMenuItem(value: _Tool.help, child: Text('Nápověda')),
        PopupMenuItem(value: _Tool.records, child: Text('Spisová služba…')),
        PopupMenuItem(value: _Tool.settings, child: Text('Nastavení…')),
      ],
    );
  }

  Future<void> _run(BuildContext context, _Tool a) async {
    final s = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    void say(String m) => messenger.showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 6)),
    );
    const zfo = XTypeGroup(label: 'Datové zprávy', extensions: ['zfo']);
    try {
      switch (a) {
        case _Tool.mobile:
          final dir = await getDirectoryPath(
            confirmButtonText: 'Importovat z této složky',
          );
          if (dir == null) return;
          say(await s.importMobile(dir));
        case _Tool.overview:
          // Current box and the date range of the advanced search, if set.
          final loc = await getSaveLocation(
            suggestedName: 'prehled-korespondence.csv',
          );
          if (loc == null) return;
          final csv = await s.correspondenceCsv(
            box: s.boxId,
            from: s.filter.from,
            to: s.filter.to,
          );
          // BOM so spreadsheet apps read Czech characters correctly.
          await File(loc.path).writeAsString('\uFEFF$csv');
          say('Přehled uložen: ${loc.path}');
        case _Tool.govServices:
          await showGovServices(context);
        case _Tool.settings:
          await showSettings(context);
        case _Tool.ai:
          await showConnectAssistant(context);
        case _Tool.help:
          await showHelp(context);
        case _Tool.records:
          await showRecordsSettings(context);
        case _Tool.verifyLocal:
          final f = await openFile(acceptedTypeGroups: [zfo]);
          if (f == null || !context.mounted) return;
          final r = await s.verifyFileLocally(f.path);
          if (context.mounted) await showSignatureReport(context, r);
        case _Tool.authenticate:
          final f = await openFile(acceptedTypeGroups: [zfo]);
          if (f == null) return;
          final ok = await s.authenticateFile(f.path);
          say(
            ok
                ? '${f.name}: ISDS potvrdil, že zpráva je pravá a nezměněná.'
                : '${f.name}: ISDS zprávu NEPOTVRDIL, soubor není pravý nebo byl změněn.',
          );
        case _Tool.import:
          final files = await openFiles(acceptedTypeGroups: [zfo]);
          if (files.isEmpty) return;
          say(await s.importZfo([for (final f in files) f.path]));
        case _Tool.backup:
          // One ZIP file, easy to move to a phone or another computer.
          final now = DateTime.now();
          final name =
              'Datovka-zaloha-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.zip';
          if (Platform.isIOS || Platform.isAndroid) {
            final path = s.tempPath(name);
            if (path == null) return;
            say(await s.backup(path));
            await s.core?.openFile(path);
            return;
          }
          final loc = await getSaveLocation(suggestedName: name);
          if (loc == null) return;
          say(await s.backup(loc.path));
        case _Tool.restore:
          const backup = XTypeGroup(
            label: 'Záloha Datovky',
            extensions: ['zip'],
            mimeTypes: ['application/zip'],
            uniformTypeIdentifiers: ['public.zip-archive'],
          );
          final dir = Platform.isAndroid
              ? await _pickBackupAndroid(s.tempPath('obnova.zip'))
              : (await openFile(acceptedTypeGroups: [backup]))?.path;
          if (dir == null || !context.mounted) return;
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Obnovit data ze zálohy?'),
              content: const Text(
                'Soubory ze zálohy přepíšou současná data. Současná data se předtím '
                'uloží vedle archivu (DATOVKA-pred-obnovou), takže o nic nepřijdete.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Zrušit'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Obnovit'),
                ),
              ],
            ),
          );
          if (ok == true) say(await s.restore(dir));
          // The copy made on Android is not needed any more.
          if (Platform.isAndroid) await File(dir).delete().catchError((_) => File(dir));
      }
    } on Object catch (e) {
      say('$e');
    }
  }
}

/// The backup ZIP on Android, copied piece by piece into [target]: the
/// file_selector plugin reads a whole file into memory, which a large archive
/// does not fit.
Future<String?> _pickBackupAndroid(String? target) async {
  if (target == null) return null;
  final f = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['zip'],
  );
  if (f == null) return null;
  final out = File(target).openWrite();
  await out.addStream(f.readAsByteStream());
  await out.close();
  return target;
}
