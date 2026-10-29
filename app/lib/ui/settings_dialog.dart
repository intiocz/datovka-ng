import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/archive_location.dart';
import '../data/data_folder.dart';
import '../data/updates.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'app_lock.dart';
import 'connect_assistant.dart';
import 'release_notes.dart';

/// Preferences of this device (⌘, on macOS).
/// [page] opens a section right away, e.g. `updates`.
Future<void> showSettings(
  BuildContext context, [
  AppState? state,
  String? page,
]) async {
  final s = state ?? AppScope.of(context);
  final repo = await ReleaseSource.repo();
  if (!context.mounted) return;
  return showDialog(
    context: context,
    builder: (_) => _SettingsDialog(
      state: s,
      repo: repo,
      page: _Page.values.where((p) => p.name == page).firstOrNull,
    ),
  );
}

enum _Page {
  sync('Stahování', Icons.sync),
  lock('Zámek', Icons.lock_outline),
  network('Síť', Icons.lan_outlined),
  archive('Archiv', Icons.folder_outlined),
  assistant('Asistent', Icons.auto_awesome_outlined),
  updates('Aktualizace', Icons.system_update_alt);

  final String label;
  final IconData icon;

  const _Page(this.label, this.icon);
}

/// Sections on the left, the chosen one on the right, like the settings of
/// a desktop app. Nothing is saved until "Uložit".
class _SettingsDialog extends StatefulWidget {
  final AppState state;
  final String repo;
  final _Page? page;

  const _SettingsDialog({required this.state, required this.repo, this.page});

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late var _st = widget.state.settings;
  late var _repo = widget.repo;
  late var _page = widget.page ?? _Page.sync;
  _Update? _update;
  ReleaseInfo? _newer;
  String _updateError = '';
  String? _lockError;

  static final _mobile =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final screen = MediaQuery.sizeOf(context);
    // A phone gets the sections as a row on top; a computer a side column.
    final narrow = screen.width < 720;

    final page = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(narrow ? 20 : 28, 24, narrow ? 20 : 28, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!narrow) ...[
            Text(_page.label, style: text.titleMedium),
            const SizedBox(height: 16),
          ],
          ..._content(context),
        ],
      ),
    );
    final actions = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zrušit'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () async {
              await _st.save();
              await ReleaseSource.save(_repo);
              widget.state.applySettings(_st);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
    final nav = [
      for (final p in _Page.values)
        if (p != _Page.lock || AppLock.available)
          _NavItem(
            page: p,
            selected: p == _page,
            column: !narrow,
            onTap: () => setState(() => _page = p),
          ),
    ];

    if (narrow) {
      return Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        child: SizedBox(
          width: screen.width,
          height: screen.height * 0.85,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text('Nastavení', style: text.titleLarge),
              ),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: nav.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (_, i) => nav[i],
                ),
              ),
              Divider(height: 1, color: t.line),
              Expanded(child: page),
              Divider(height: 1, color: t.line),
              actions,
            ],
          ),
        ),
      );
    }

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 760,
        height: 520,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 200,
              color: t.paper,
              padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: Text('Nastavení', style: text.titleLarge),
                  ),
                  ...nav,
                ],
              ),
            ),
            VerticalDivider(width: 1, color: t.line),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: page),
                  Divider(height: 1, color: t.line),
                  actions,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Switches to another archive folder; one without `dsgui.conf` is only
  /// used after the user confirms a new, empty archive there.
  Future<void> _pickArchive(BuildContext context) async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null || !context.mounted) return;
    // On a phone: keep access to the folder and bring its files from iCloud
    // Drive first, otherwise dsgui.conf may look missing.
    await DataFolder.remember(dir);
    await DataFolder.materialize(dir);
    if (!context.mounted) return;
    // In iCloud Drive the file may only be a placeholder on a phone so far.
    if (!File('$dir/dsgui.conf').existsSync() &&
        !File('$dir/.dsgui.conf.icloud').existsSync()) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ve složce není archiv'),
          content: Text(
            'Složka $dir neobsahuje dsgui.conf, tedy archiv Datovky. '
            'Vybrali jste správnou složku? Pokud ano, začne v ní nový, prázdný archiv.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vybrat jinou'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Začít nový archiv'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await widget.state.useDataDir(dir);
    if (context.mounted) setState(() {});
  }

  /// The answer stays right under the button, not in a message behind the
  /// dialog.
  Future<void> _checkUpdate() async {
    setState(() => _update = _Update.checking);
    try {
      await ReleaseSource.save(_repo);
      final info = await newerRelease();
      if (!mounted) return;
      setState(() {
        _newer = info;
        _update = info == null ? _Update.current : _Update.newer;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _updateError = '$e';
          _update = _Update.failed;
        });
      }
    }
  }

  Future<void> _installUpdate() async {
    final info = _newer!;
    if (!canInstall(info)) {
      await openLink(info.page);
      return;
    }
    setState(() => _update = _Update.installing);
    try {
      // A Mac and Windows quit here and start the new version.
      await installRelease(info);
      if (mounted) setState(() => _update = _Update.installed);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _updateError = '$e';
          _update = _Update.failed;
        });
      }
    }
  }

  List<Widget> _content(BuildContext context) {
    final s = widget.state;
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    switch (_page) {
      case _Page.sync:
        return [
          _Group(
            children: [
              _Row(
                title: 'Automaticky stahovat',
                trailing: DropdownButton<int>(
                  value: _st.syncMinutes,
                  underline: const SizedBox(),
                  borderRadius: BorderRadius.circular(8),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Nikdy')),
                    DropdownMenuItem(value: 5, child: Text('Každých 5 minut')),
                    DropdownMenuItem(
                      value: 15,
                      child: Text('Každých 15 minut'),
                    ),
                    DropdownMenuItem(
                      value: 30,
                      child: Text('Každých 30 minut'),
                    ),
                    DropdownMenuItem(value: 60, child: Text('Každou hodinu')),
                    DropdownMenuItem(value: 240, child: Text('Každé 4 hodiny')),
                  ],
                  onChanged: (v) =>
                      setState(() => _st = _st.copyWith(syncMinutes: v)),
                ),
              ),
              _Row(
                title: 'Stáhnout nové zprávy po spuštění',
                trailing: Switch(
                  value: _st.syncOnStart,
                  onChanged: (v) =>
                      setState(() => _st = _st.copyWith(syncOnStart: v)),
                ),
              ),
              _Row(
                title: 'Označovat přečtení i v ISDS',
                subtitle: 'Otevřená zpráva bude přečtená i na portálu datových schránek.',
                trailing: Switch(
                  value: _st.markReadInIsds,
                  onChanged: (v) =>
                      setState(() => _st = _st.copyWith(markReadInIsds: v)),
                ),
              ),
            ],
          ),
          const _Note(
            'Stahuje se jen ze schránek s uloženým heslem nebo s platným '
            'přihlášením. Přihlášení do schránky ISDS počítá jako doručení '
            'čekajících zpráv.',
          ),
        ];
      case _Page.lock:
        return [
          _Group(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppLock.enabled,
                builder: (context, on, _) => _Row(
                  title: 'Zamykat aplikaci',
                  subtitle:
                      'Při spuštění a po návratu do aplikace se zeptá na '
                      'Face ID nebo kód telefonu.',
                  trailing: Switch(
                    value: on,
                    onChanged: (v) async {
                      setState(() => _lockError = null);
                      try {
                        await AppLock.setEnabled(v);
                      } on Object catch (e) {
                        if (mounted) setState(() => _lockError = '$e');
                      }
                    },
                  ),
                ),
              ),
              if (_lockError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _lockError!,
                    style: text.bodyMedium?.copyWith(color: t.danger),
                  ),
                ),
            ],
          ),
          const _Note(
            'Telefon se zeptá na Face ID, a když nejde, na svůj kód. Datovka si '
            'žádný vlastní PIN nevymýšlí. Hesla ke schránkám jsou dál v Klíčence.',
          ),
        ];
      case _Page.network:
        return [
          _Field(
            label: 'Proxy',
            child: TextFormField(
              initialValue: _st.proxy,
              decoration: const InputDecoration(
                hintText: 'http://proxy.firma.cz:3128',
              ),
              onChanged: (v) => _st = _st.copyWith(proxy: v.trim()),
            ),
          ),
          const _Note(
            'Nechte prázdné, použije se nastavení systému. Proxy potřebujete '
            'jen ve firemní síti, která jinak nepustí ven.',
          ),
        ];
      case _Page.archive:
        return [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: t.paper,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 18, color: t.inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    s.dataDir ?? 'Archiv není otevřený',
                    style: text.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Group(
            children: [
              _Row(
                title: 'Otevřít jiný archiv',
                subtitle: _mobile
                    ? 'Např. iCloud Drive → Datovka archiv, stejný jako na počítači.'
                    : 'Složka s dsgui.conf, třeba archiv na iCloud Drive.',
                trailing: OutlinedButton(
                  onPressed: () => _pickArchive(context),
                  child: const Text('Vybrat…'),
                ),
              ),
              if (ArchiveLocation.isLocalLegacy(s.dataDir) &&
                  defaultTargetPlatform == TargetPlatform.macOS)
                _Row(
                  title: 'Přesunout archiv do Dokumentů',
                  subtitle:
                      'Teď je ve skryté složce původní Datovky. V Dokumentech '
                      'ho uvidíte a zálohuje ho iCloud.',
                  trailing: OutlinedButton(
                    onPressed: () async {
                      try {
                        final to =
                            await ArchiveLocation.copyLegacyIntoDocuments();
                        await s.useDataDir(to);
                        if (context.mounted) Navigator.pop(context);
                      } on Object catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('$e')));
                        }
                      }
                    },
                    child: const Text('Zkopírovat'),
                  ),
                ),
            ],
          ),
          const _Note(
            'Stejnou složku může mít otevřenou telefon i několik počítačů '
            'naráz. Stahování počká, když do ní právě zapisuje jiné zařízení.',
          ),
        ];
      case _Page.assistant:
        return [
          _Group(
            children: [
              _Row(
                title: 'AI asistent',
                subtitle:
                    'Najde v přílohách lhůty a navrhne štítky. Vyberete, který '
                    'model použít.',
                trailing: OutlinedButton(
                  onPressed: () => showConnectAssistant(context),
                  child: const Text('Připojit…'),
                ),
              ),
            ],
          ),
        ];
      case _Page.updates:
        final busy =
            _update == _Update.checking || _update == _Update.installing;
        return [
          _Group(
            children: [
              _Row(
                title: 'Datovka NG $appVersion',
                subtitle: 'Nové verze se stahují z vydání na GitHubu.',
                trailing: FilledButton.tonal(
                  onPressed: busy ? null : _checkUpdate,
                  child: const Text('Zkontrolovat'),
                ),
              ),
              if (_update != null) _UpdateStatus(this),
            ],
          ),
          const SizedBox(height: 20),
          _Field(
            label: 'Repozitář na GitHubu',
            child: TextFormField(
              initialValue: _repo,
              decoration: const InputDecoration(hintText: 'intiocz/datovka-ng'),
              onChanged: (v) => _repo = v,
            ),
          ),
          const _Note('Měňte jen, když vám to někdo poradí.'),
        ];
    }
  }
}

class _NavItem extends StatelessWidget {
  final _Page page;
  final bool selected;
  final VoidCallback onTap;

  /// In the side column the label takes the rest of the width.
  final bool column;

  const _NavItem({
    required this.page,
    required this.selected,
    required this.onTap,
    this.column = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final label = Text(
      page.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: text.bodyMedium?.copyWith(
        color: selected ? t.accent : t.ink,
        fontWeight: selected ? FontWeight.w600 : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? t.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  page.icon,
                  size: 18,
                  color: selected ? t.accent : t.inkMuted,
                ),
                const SizedBox(width: 10),
                if (column) Expanded(child: label) else label,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rows on one card, separated by thin lines.
class _Group extends StatelessWidget {
  final List<Widget> children;

  const _Group({required this.children});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    if (children.isEmpty) return const SizedBox();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, c) in children.indexed) ...[
            if (i > 0) Divider(height: 1, color: t.line),
            c,
          ],
        ],
      ),
    );
  }
}

/// A text field with its label above, so the label never sits on the border.
class _Field extends StatelessWidget {
  final String label;
  final Widget child;

  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ),
      child,
    ],
  );
}

class _Note extends StatelessWidget {
  final String text;

  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Tokens.of(context).inkMuted),
    ),
  );
}

/// One setting: what it is on the left, the control on the right.
class _Row extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget trailing;

  const _Row({required this.title, required this.trailing, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: text.bodyMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: text.bodySmall?.copyWith(color: t.inkMuted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            trailing,
          ],
        ),
      ),
    );
  }
}

enum _Update { checking, current, newer, installing, installed, failed }

/// Result of the update check, inside the same box as the button.
class _UpdateStatus extends StatelessWidget {
  final _SettingsDialogState owner;

  const _UpdateStatus(this.owner);

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final info = owner._newer;

    Widget line(Widget lead, String msg, {Color? color}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 20, height: 20, child: Center(child: lead)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(msg, style: text.bodyMedium?.copyWith(color: color)),
        ),
      ],
    );
    const spinner = SizedBox.square(
      dimension: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );

    final Widget body = switch (owner._update!) {
      _Update.checking => line(spinner, 'Hledám novou verzi…'),
      _Update.current => line(
        Icon(Icons.check_circle, size: 18, color: t.ok),
        'Máte nejnovější verzi $appVersion.',
      ),
      _Update.failed => line(
        Icon(Icons.error_outline, size: 18, color: t.danger),
        owner._updateError,
        color: t.danger,
      ),
      _Update.installing => line(
        spinner,
        'Stahuji verzi ${info?.version}. Aplikace se pak sama spustí znovu.',
      ),
      _Update.installed => line(
        Icon(Icons.check_circle, size: 18, color: t.ok),
        'Verze ${info?.version} je nainstalovaná. Spusťte Datovku znovu.',
      ),
      _Update.newer => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(
            Icon(Icons.new_releases_outlined, size: 18, color: t.accent),
            'K dispozici je verze ${info!.version}.',
            color: t.accent,
          ),
          if (info.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: ReleaseNotes(info.notes, style: text.bodySmall),
            ),
          ],
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: FilledButton(
              onPressed: owner._installUpdate,
              child: Text(canInstall(info) ? 'Aktualizovat' : 'Otevřít vydání'),
            ),
          ),
        ],
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: body,
    );
  }
}
