import 'package:flutter/material.dart';

import '../data/updates.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'help_view.dart';

/// Bottom line: what the app is doing, and who pays for the work.
class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  @override
  void initState() {
    super.initState();
    if (!checkUpdatesOnStart) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) offerUpdate(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final busy = s.sync.running || s.listLoading;
    final label = s.sync.running
        ? 'Stahuji nové zprávy…'
        : s.listLoading
        ? 'Načítám zprávy…'
        : s.activity;
    // Above the home indicator and clear of a phone's rounded corners; the
    // colour still reaches the edge.
    return Material(
      color: t.paper,
      shape: Border(top: BorderSide(color: t.line)),
      child: SafeArea(
        top: false,
        minimum: MediaQuery.paddingOf(context).bottom > 0
            ? const EdgeInsets.symmetric(horizontal: 8)
            : EdgeInsets.zero,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: t.accent,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.circle, size: 8, color: t.ok),
                ),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ),
              TextButton(
                onPressed: () => showHelp(context),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Nápověda'),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Vývoj Datovky NG platí projekt NENDE.cz, monitoring veřejných zakázek.',
                child: InkWell(
                  onTap: () => openLink(nendeLink('status-bar')),
                  child: Text(
                    // A phone has room for the name only.
                    MediaQuery.sizeOf(context).width < 520
                        ? 'NENDE.cz'
                        : 'Vývoj je podporován NENDE.cz',
                    style: text.bodySmall?.copyWith(
                      color: t.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
