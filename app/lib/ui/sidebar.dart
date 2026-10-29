import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'box_info.dart';
import 'compose.dart';
import 'format.dart';
import 'login_dialog.dart';
import 'tools.dart';

class Sidebar extends StatelessWidget {
  final VoidCallback? onPicked;

  const Sidebar({super.key, this.onPicked});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;

    void pickBox(String? id) {
      s.selectBox(id);
      onPicked?.call();
    }

    final phone =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    void pickFolder(Folder f) {
      s.selectFolder(f);
      onPicked?.call();
    }

    return Container(
      color: t.paper,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
              child: Row(
                children: [
                  const _Mark(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Datovka NG',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: t.accentSoft,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'alfa',
                      style: text.labelSmall?.copyWith(
                        color: t.accent,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: FilledButton.icon(
                onPressed: () => showCompose(context),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Napsat zprávu'),
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  minimumSize: const Size.fromHeight(40),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  _FolderTree(
                    folder: Folder.inbox,
                    label: 'Přijaté',
                    icon: Icons.inbox_outlined,
                    count: s.unreadIn(s.boxId),
                    onPicked: onPicked,
                  ),
                  _FolderTree(
                    folder: Folder.sent,
                    label: 'Odeslané',
                    icon: Icons.outbox_outlined,
                    onPicked: onPicked,
                  ),
                  _Item(
                    label: 'Lhůty',
                    icon: Icons.timer_outlined,
                    selected:
                        s.view == Screen.messages &&
                        s.folder == Folder.deadlines,
                    count: s.openDeadlines,
                    countMuted: true,
                    onTap: () => pickFolder(Folder.deadlines),
                  ),
                  _FolderTree(
                    folder: Folder.all,
                    label: 'Všechny zprávy',
                    icon: Icons.archive_outlined,
                    onPicked: onPicked,
                  ),
                  _Item(
                    label: 'Koncepty',
                    icon: Icons.drafts_outlined,
                    selected:
                        s.view == Screen.messages && s.folder == Folder.drafts,
                    count: s.draftCount,
                    countMuted: true,
                    onTap: () => pickFolder(Folder.drafts),
                  ),
                  _Item(
                    label: 'Adresář schránek',
                    icon: Icons.travel_explore_outlined,
                    selected: s.view == Screen.directory,
                    onTap: () {
                      s.openDirectory();
                      onPicked?.call();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 22, 4, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Schránky',
                            style: text.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Přidat schránku',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => showAddBoxDialog(context),
                          icon: Icon(Icons.add, size: 18, color: t.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  _BoxItem(
                    title: 'Všechny schránky',
                    selected: s.boxId == null,
                    unread: s.unreadIn(null),
                    onTap: () => pickBox(null),
                  ),
                  // A computer drags boxes to change the order, saved like the
                  // original app. On a phone dragging fights with scrolling, so
                  // the boxes are just in alphabetical order there.
                  if (phone)
                    for (final b in [...s.boxes]..sort(
                      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                    ))
                      _BoxItem(
                        title: b.name,
                        tooltip: '${b.kind}, ID ${b.isdsId ?? b.id}, ${b.login.label}.',
                        selected: s.boxId == b.id,
                        unread: s.unreadIn(b.id),
                        needsLogin: !b.canSyncUnattended,
                        onTap: () => pickBox(b.id),
                        onMenu: (pos) => _boxMenu(context, pos, b),
                      )
                  else
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorderItem: s.moveBox,
                      children: [
                        for (final (i, b) in s.boxes.indexed)
                          ReorderableDragStartListener(
                            key: ValueKey(b.id),
                            index: i,
                            child: _BoxItem(
                              title: b.name,
                              tooltip:
                                  '${b.kind}, ID ${b.isdsId ?? b.id}, ${b.login.label}. Přetažením změníte pořadí.',
                              selected: s.boxId == b.id,
                              unread: s.unreadIn(b.id),
                              needsLogin: !b.canSyncUnattended,
                              onTap: () => pickBox(b.id),
                              onMenu: (pos) => _boxMenu(context, pos, b),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const _ToolsLink(),
            _SyncFooter(state: s),
          ],
        ),
      ),
    );
  }
}

/// The app logo as in `branding/web/favicon.svg`: the yellow mark (two
/// arrows in a frame) on a blue rounded tile.
class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 24,
    child: CustomPaint(painter: _MarkPainter()),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  static const blue = Color(0xFF2D4E7C);
  static const yellow = Color(0xFFF2B835);

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on the 64-unit grid of the favicon.
    final k = size.width / 64;
    canvas.scale(k);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 64, 64),
        const Radius.circular(14.3),
      ),
      Paint()..color = blue,
    );
    canvas.translate(14.08, 21.28);
    canvas.scale(0.32);
    Paint line(double w) => Paint()
      ..color = yellow
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeJoin = StrokeJoin.miter;
    canvas.drawRect(const Rect.fromLTWH(-16, -16, 144, 99), line(8));
    final arrows = Path()
      ..moveTo(67, 7.5)
      ..lineTo(104.5, 7.5)
      ..lineTo(104.5, 67)
      ..moveTo(104.5, 7.5)
      ..lineTo(58, 54)
      ..moveTo(45, 59.5)
      ..lineTo(7.5, 59.5)
      ..lineTo(7.5, 0)
      ..moveTo(7.5, 59.5)
      ..lineTo(54, 13);
    canvas.drawPath(arrows, line(15));
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}

/// A folder with its years and months below, like the tree in the original
/// Datovka. The arrow only opens and closes; the name shows the messages.
class _FolderTree extends StatelessWidget {
  final Folder folder;
  final String label;
  final IconData icon;
  final int count;
  final VoidCallback? onPicked;

  const _FolderTree({
    required this.folder,
    required this.label,
    required this.icon,
    this.count = 0,
    this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final here = s.view == Screen.messages && s.folder == folder;
    final period = here ? s.filter.period : null;
    final key = folder.name;
    final open = s.treeOpen.contains(key);
    final months = open ? s.treeMonths(folder) : null;
    final years = <int, int>{};
    for (final e in (months ?? const <String, int>{}).entries) {
      final y = int.tryParse(e.key.substring(0, 4));
      if (y != null) years[y] = (years[y] ?? 0) + e.value;
    }
    final sorted = years.keys.toList()..sort((a, b) => b.compareTo(a));

    void pick(int? year, [int? month]) {
      s.openPeriod(folder, year, month);
      onPicked?.call();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Item(
          label: label,
          icon: icon,
          selected: here && period == null,
          count: count,
          expanded: open,
          onExpand: () => s.toggleTree(key),
          onTap: () => pick(null),
        ),
        if (open && months == null)
          const Padding(
            padding: EdgeInsets.fromLTRB(52, 6, 0, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        if (open)
          for (final y in sorted) ...[
            _Item(
              label: '$y',
              depth: 1,
              selected: period?.year == y && period?.month == null,
              count: years[y]!,
              countMuted: true,
              expanded: s.treeOpen.contains('$key/$y'),
              onExpand: () => s.toggleTree('$key/$y'),
              onTap: () => pick(y),
            ),
            if (s.treeOpen.contains('$key/$y'))
              for (var mo = 12; mo >= 1; mo--)
                if ((months!['$y-${mo.toString().padLeft(2, '0')}'] ?? 0) > 0)
                  _Item(
                    label: monthNames[mo - 1],
                    depth: 2,
                    selected: period?.year == y && period?.month == mo,
                    count: months['$y-${mo.toString().padLeft(2, '0')}']!,
                    countMuted: true,
                    onTap: () => pick(y, mo),
                  ),
          ],
      ],
    );
  }
}

class _Item extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final int count;
  final bool countMuted;
  final VoidCallback onTap;

  /// Level in the folder tree: 0 folder, 1 year, 2 month.
  final int depth;

  /// Set for rows that open below: the arrow in front toggles them.
  final bool? expanded;
  final VoidCallback? onExpand;

  const _Item({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.count = 0,
    this.countMuted = false,
    this.depth = 0,
    this.expanded,
    this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: selected
          ? FontWeight.w700
          : depth == 0
          ? FontWeight.w500
          : FontWeight.w400,
      color: selected ? t.accent : t.ink,
    );
    // Folders keep their icon in line; the arrow sits in the left margin.
    final arrow = SizedBox(
      width: 22,
      child: expanded == null
          ? null
          : InkResponse(
              onTap: onExpand,
              radius: 14,
              child: Icon(
                expanded! ? Icons.expand_more : Icons.chevron_right,
                size: 18,
                color: t.inkMuted,
              ),
            ),
    );
    return Padding(
      padding: EdgeInsets.only(top: 1, bottom: 1, left: depth * 18.0),
      child: Material(
        color: selected ? t.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              depth == 0 ? 9 : 6,
              12,
              depth == 0 ? 9 : 6,
            ),
            child: Row(
              children: [
                arrow,
                if (icon != null) ...[
                  Icon(icon, size: 19, color: selected ? t.accent : t.inkMuted),
                  const SizedBox(width: 12),
                ],
                Expanded(child: Text(label, style: style)),
                if (count > 0)
                  Text(
                    '$count',
                    style: style?.copyWith(
                      fontFeatures: tabular,
                      color: countMuted ? t.inkMuted : t.accent,
                      fontWeight: depth == 0 ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _renameBox(BuildContext context, DataBox b) async {
  final s = AppScope.of(context);
  final field = TextEditingController(text: b.name);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Přejmenovat schránku'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Jméno v seznamu. Oficiální název v datové schránce se nemění. '
              'Uloží se do archivu, takže ho uvidíte i na ostatních zařízeních.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: field,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Jméno'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, field.text),
          child: const Text('Uložit'),
        ),
      ],
    ),
  );
  field.dispose();
  if (name != null && context.mounted) s.renameBox(b, name);
}

Future<void> _boxMenu(BuildContext context, Offset pos, DataBox b) async {
  final s = AppScope.of(context);
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: [
      const PopupMenuItem(value: 'info', child: Text('Informace o schránce')),
      const PopupMenuItem(value: 'rename', child: Text('Přejmenovat')),
      const PopupMenuItem(
        value: 'method',
        child: Text('Způsob přihlášení…'),
      ),
      if (b.session != Session.active)
        const PopupMenuItem(value: 'login', child: Text('Přihlásit'))
      else
        const PopupMenuItem(value: 'logout', child: Text('Odhlásit')),
      const PopupMenuItem(
        value: 'write',
        child: Text('Napsat zprávu z této schránky'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'remove', child: Text('Odebrat schránku…')),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'info':
      await showBoxInfo(context, b);
    case 'rename':
      await _renameBox(context, b);
    case 'method':
      await showChangeLoginDialog(context, b);
    case 'login':
      await showLoginDialog(context, b);
    case 'logout':
      s.logout(b);
    case 'write':
      await showCompose(context, Draft(fromBoxId: b.id));
    case 'remove':
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Odebrat schránku ${b.name}?'),
          content: const Text(
            'Schránka zmizí ze seznamu a uložené přihlašovací údaje se smažou. '
            'Archiv zpráv zůstane ve složce dat, po opětovném přidání se znovu zobrazí.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Odebrat'),
            ),
          ],
        ),
      );
      if (ok == true) s.removeBox(b);
  }
}

class _BoxItem extends StatelessWidget {
  final void Function(Offset globalPosition)? onMenu;
  final String title;
  final String? tooltip;
  final bool selected;
  final int unread;
  final bool needsLogin;
  final VoidCallback onTap;

  const _BoxItem({
    required this.title,
    required this.selected,
    required this.onTap,
    this.tooltip,
    this.unread = 0,
    this.needsLogin = false,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final row = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onSecondaryTapUp: onMenu == null
          ? null
          : (d) => onMenu!(d.globalPosition),
      onLongPress: onMenu == null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox?;
              onMenu!(box?.localToGlobal(Offset.zero) ?? Offset.zero);
            },
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? t.accentSoft : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(
                  fontWeight: selected || unread > 0
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: selected ? t.accent : t.ink,
                ),
              ),
            ),
            if (needsLogin)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.key_outlined, size: 15, color: t.warn),
              ),
            if (unread > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '$unread',
                  style: text.bodySmall?.copyWith(
                    fontFeatures: tabular,
                    fontWeight: FontWeight.w700,
                    color: t.accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: tooltip == null
          ? row
          : Tooltip(
              message: tooltip!,
              waitDuration: const Duration(milliseconds: 600),
              child: row,
            ),
    );
  }
}

/// Tools as a visible row right above the archive status.
class _ToolsLink extends StatelessWidget {
  const _ToolsLink();

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
      child: ToolsMenu(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Icon(Icons.handyman_outlined, size: 18, color: t.inkMuted),
              const SizedBox(width: 12),
              Expanded(child: Text('Nástroje', style: text.bodyMedium)),
              Icon(Icons.expand_more, size: 18, color: t.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncFooter extends StatelessWidget {
  final AppState state;

  const _SyncFooter({required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final sync = state.sync;
    final notes = <Widget>[
      for (final e in state.passwordExpiry.entries)
        if (daysUntil(e.value) <= 14)
          Text(
            '${state.boxById(e.key)?.name ?? e.key}: heslo vyprší ${daysUntil(e.value) <= 0 ? 'dnes' : 'za ${days(daysUntil(e.value))}'}',
            style: text.bodySmall?.copyWith(color: t.warn),
          ),
      if (state.syncError != null)
        Text(state.syncError!, style: text.bodySmall?.copyWith(color: t.danger)),
      if (state.foreignLock != null)
        Text(
          '${state.foreignLock!.device} právě zapisuje, čtení funguje',
          style: text.bodySmall?.copyWith(color: t.warn),
        ),
      if (state.needLogin.isNotEmpty)
        Text(switch (state.needLogin.length) {
          1 => '1 schránka čeká na přihlášení',
          < 5 && final n => '$n schránky čekají na přihlášení',
          final n => '$n schránek čeká na přihlášení',
        }, style: text.bodySmall?.copyWith(color: t.warn)),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                state.foreignLock != null
                    ? Icons.lock_outline
                    // A cloud only when the archive really is in iCloud Drive.
                    : sync.storageName == 'iCloud Drive'
                    ? Icons.cloud_done_outlined
                    : Icons.check_circle_outline,
                size: 18,
                color: state.foreignLock == null ? t.ok : t.warn,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Archiv: ${sync.storageName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: t.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      sync.running
                          ? 'Stahuji nové zprávy…'
                          : sync.lastSync == null
                          ? 'Zatím nestaženo'
                          : 'Staženo ${relativeAgo(sync.lastSync!)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Stáhnout nové zprávy',
                onPressed: sync.running ? null : state.runSync,
                icon: sync.running
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: t.accent,
                        ),
                      )
                    : Icon(Icons.refresh, size: 20, color: t.inkMuted),
              ),
            ],
          ),
          // Messages get the full width of the sidebar below the buttons.
          if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: notes,
              ),
            ),
        ],
      ),
    );
  }
}
