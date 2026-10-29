import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'compose.dart';
import 'deadline.dart';
import 'format.dart';
import 'login_dialog.dart';
import 'message_actions.dart';
import 'search_filter.dart';

class MessageList extends StatelessWidget {
  final void Function(Message m) onOpen;
  final Widget? leading;

  const MessageList({super.key, required this.onOpen, this.leading});

  String _title(Folder f) => switch (f) {
    Folder.inbox => 'Přijaté',
    Folder.sent => 'Odeslané',
    Folder.deadlines => 'Lhůty',
    Folder.all => 'Všechny zprávy',
    Folder.drafts => 'Koncepty',
  };

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final items = s.visible;
    final box = s.boxId == null ? null : s.boxById(s.boxId!);

    return Container(
      color: t.surface,
      child: SafeArea(
        left: false,
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 4),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 4)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_title(s.folder), style: text.headlineSmall),
                        Text(
                          box?.name ?? 'Všechny schránky',
                          style: text.bodySmall,
                        ),
                        if (s.filter.period != null) const _PeriodTag(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: s.searchBox,
                      focusNode: s.searchFocus,
                      onChanged: s.search,
                      style: text.bodyMedium,
                      decoration: InputDecoration(
                        hintStyle: text.bodyMedium?.copyWith(color: t.inkMuted),
                        hintText: 'Hledat podle věci, odesílatele nebo č. j.',
                        prefixIcon: Icon(
                          Icons.search,
                          size: 20,
                          color: t.inkMuted,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 40,
                        ),
                        suffixIcon: s.query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Smazat hledání',
                                onPressed: () => s.search(''),
                                icon: Icon(
                                  Icons.close,
                                  size: 18,
                                  color: t.inkMuted,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Pokročilé hledání',
                    onPressed: () => showSearchFilter(context),
                    icon: Badge(
                      isLabelVisible: s.filter.activeBesidesPeriod,
                      smallSize: 8,
                      child: Icon(
                        Icons.tune,
                        color: s.filter.activeBesidesPeriod
                            ? t.accent
                            : t.inkMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (s.listLoading) const LinearProgressIndicator(minHeight: 2),
            if (s.pinLocked) const _PinBanner(),
            if (s.foreignLock != null) const _LockBanner(),
            if (s.picked.isNotEmpty) const _PickBanner(),
            if (s.error != null)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                decoration: BoxDecoration(
                  color: t.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.error!,
                        style: text.bodySmall?.copyWith(color: t.danger),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zavřít',
                      visualDensity: VisualDensity.compact,
                      onPressed: s.dismissError,
                      icon: Icon(Icons.close, size: 16, color: t.danger),
                    ),
                  ],
                ),
              ),
            for (final b in s.needLogin.where(
              (b) => s.boxId == null || b.id == s.boxId,
            ))
              _LoginBanner(box: b),
            Divider(height: 1, color: t.line),
            Expanded(
              child: s.folder == Folder.drafts
                  ? DraftList(boxId: s.boxId)
                  : items.isEmpty
                  ? _Empty(searching: s.query.isNotEmpty, folder: s.folder)
                  : ListView.separated(
                      itemCount: items.length + (s.canLoadMore ? 1 : 0),
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, indent: 20, color: t.line),
                      itemBuilder: (context, i) {
                        if (i >= items.length) {
                          return TextButton(
                            onPressed: s.loadMore,
                            child: Text(
                              'Načíst další (${items.length} z ${s.listTotal})',
                            ),
                          );
                        }
                        final m = items[i];
                        return _Reveal(
                          selected: m.dmId == s.selectedId,
                          child: _Row(
                            m: m,
                            selected:
                                m.dmId == s.selectedId ||
                                s.picked.contains(m.dmId),
                            showBox: s.boxId == null && s.boxes.length > 1,
                            onTap: () {
                              final keys = HardwareKeyboard.instance;
                              final toggle =
                                  keys.isMetaPressed || keys.isControlPressed;
                              if (toggle || keys.isShiftPressed) {
                                s.pick(
                                  m,
                                  range: keys.isShiftPressed && !toggle,
                                );
                                return;
                              }
                              onOpen(m);
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final Message m;
  final bool selected;
  final bool showBox;
  final VoidCallback onTap;

  const _Row({
    required this.m,
    required this.selected,
    required this.showBox,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final s = AppScope.of(context);
    final unread = !m.isRead && m.direction == Direction.received;
    final party = text.bodyMedium?.copyWith(
      fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
      color: unread ? t.ink : t.inkMuted,
    );

    return Material(
      color: selected ? t.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: (d) => showMessageMenu(context, d.globalPosition, m),
        onLongPress: () {
          final box = context.findRenderObject() as RenderBox?;
          showMessageMenu(
            context,
            box?.localToGlobal(const Offset(40, 20)) ?? Offset.zero,
            m,
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 14,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: unread
                      ? Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: t.accent,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                if (m.direction == Direction.sent)
                                  TextSpan(
                                    text: 'Komu: ',
                                    style: text.labelMedium?.copyWith(
                                      color: t.accent,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                TextSpan(text: m.counterparty, style: party),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          shortDate(m.delivered),
                          style: text.bodySmall?.copyWith(
                            fontFeatures: tabular,
                            color: unread ? t.accent : t.inkMuted,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      m.subject,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (m.processState != ProcessState.unsettled) ...[
                          Tooltip(
                            message: m.processState.label,
                            child: Icon(
                              m.processState == ProcessState.settled
                                  ? Icons.task_alt
                                  : Icons.pending_outlined,
                              size: 14,
                              color: m.processState == ProcessState.settled
                                  ? t.ok
                                  : t.warn,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (m.attachments.isNotEmpty) ...[
                          Icon(Icons.attach_file, size: 14, color: t.inkMuted),
                          Text(
                            '${m.attachments.length}',
                            style: text.bodySmall?.copyWith(
                              fontFeatures: tabular,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (showBox)
                          Flexible(
                            child: Text(
                              s.boxById(m.boxId)?.name ?? m.boxId,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall,
                            ),
                          ),
                        for (final tag in m.tags) ...[
                          const SizedBox(width: 8),
                          Text(
                            '#$tag',
                            style: text.bodySmall?.copyWith(color: t.accent),
                          ),
                        ],
                      ],
                    ),
                    if (m.deadline != null) ...[
                      const SizedBox(height: 8),
                      DeadlineBar(start: m.delivered, end: m.deadline!),
                    ],
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

/// Scrolls the newly selected row into view (keyboard movement) by as little
/// as needed. A row that is already visible, e.g. one just clicked, stays put.
class _Reveal extends StatefulWidget {
  final bool selected;
  final Widget child;

  const _Reveal({required this.selected, required this.child});

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> {
  @override
  void didUpdateWidget(_Reveal old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        for (final policy in [
          ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ]) {
          if (!mounted) return;
          await Scrollable.ensureVisible(
            context,
            alignmentPolicy: policy,
            duration: const Duration(milliseconds: 120),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PickBanner extends StatelessWidget {
  const _PickBanner();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final n = s.picked.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: t.accentSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$n vybraných',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: s.markPickedRead,
            child: const Text('Přečtené'),
          ),
          TextButton(onPressed: s.clearPicked, child: const Text('Zrušit')),
        ],
      ),
    );
  }
}

class _LockBanner extends StatelessWidget {
  const _LockBanner();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final lock = s.foreignLock!;
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final when = lock.stale
        ? 'Zámek už se neozývá, jde ho převzít.'
        : 'Čtení funguje. Stahování počká, až skončí, nebo ho převezměte, když je to zařízení vypnuté.';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: t.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: t.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${lock.device} právě zapisuje. $when',
              style: text.bodySmall?.copyWith(color: t.ink),
            ),
          ),
          TextButton(onPressed: s.runSync, child: const Text('Znovu')),
          TextButton(onPressed: s.takeOverLock, child: const Text('Převzít')),
        ],
      ),
    );
  }
}

/// Asks for the PIN that protects stored passwords; shown inline, not as a popup.
class _PinBanner extends StatelessWidget {
  const _PinBanner();

  Future<void> _ask(BuildContext context) async {
    final s = AppScope.of(context);
    final c = TextEditingController();
    String? err;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          void submit() {
            if (s.unlockPin(c.text)) {
              Navigator.pop(ctx);
            } else {
              setState(() => err = 'Nesprávný PIN');
            }
          }

          return AlertDialog(
            title: const Text('Zadat PIN'),
            content: TextField(
              controller: c,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: 'PIN', errorText: err),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Zrušit'),
              ),
              FilledButton(onPressed: submit, child: const Text('Odemknout')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: t.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: t.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Uložená hesla jsou chráněná PINem. Bez něj se zprávy nestahují.',
              style: text.bodySmall?.copyWith(color: t.ink),
            ),
          ),
          TextButton(
            onPressed: () => _ask(context),
            child: const Text('Zadat PIN'),
          ),
        ],
      ),
    );
  }
}

/// Quiet, inline notice for a box whose session expired. Never a popup.
class _LoginBanner extends StatelessWidget {
  final DataBox box;

  const _LoginBanner({required this.box});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: t.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.key_outlined, size: 16, color: t.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: box.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(
                    text: ': přihlášení vypršelo, nové zprávy se nestahují.',
                  ),
                ],
              ),
              style: text.bodySmall?.copyWith(color: t.ink),
            ),
          ),
          TextButton(
            onPressed: () => showLoginDialog(context, box),
            child: const Text('Přihlásit'),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final bool searching;
  final Folder folder;

  const _Empty({required this.searching, required this.folder});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = AppScope.of(context);
    // An archive without any box is usually the wrong folder, not an empty one.
    final noBoxes = s.live && s.boxes.isEmpty && !s.listLoading;
    final (title, body) = noBoxes
        ? (
            'V archivu nejsou žádné schránky',
            'Otevřená složka: ${s.dataDir ?? '?'}\n'
                'Pokud to není archiv Datovky (složka s dsgui.conf), vyberte '
                'správný v Nástroje → Nastavení → Archiv → Otevřít jiný archiv, '
                'nebo schránku přidejte tlačítkem + u Schránek.',
          )
        : searching
        ? (
            'Nic nenalezeno',
            'Zkuste jiné slovo. Hledá se ve věci, odesílateli, příjemci a číslech jednacích.',
          )
        : switch (folder) {
            Folder.deadlines => (
              'Žádné hlídané lhůty',
              'U zprávy, na kterou musíte reagovat, nastavte lhůtu. Ukáže se tady a v seznamu.',
            ),
            _ => (
              'Žádné zprávy',
              'Nové zprávy stáhnete tlačítkem obnovit vlevo dole.',
            ),
          };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: text.titleMedium),
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center, style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// The year or month picked in the sidebar tree, with a way back to all.
class _PeriodTag extends StatelessWidget {
  const _PeriodTag();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: t.accentSoft,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => s.showPeriod(null),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 3, 6, 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_month_outlined, size: 14, color: t.accent),
                const SizedBox(width: 6),
                Text(
                  periodLabel(s.filter.period!),
                  style: text.bodySmall?.copyWith(
                    color: t.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Zobrazit celé období',
                  child: Icon(Icons.close, size: 14, color: t.accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
