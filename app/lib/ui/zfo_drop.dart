import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_scope.dart';

/// Lets ZFO files be dropped anywhere on the window to import them into the
/// box they belong to.
class ZfoDrop extends StatefulWidget {
  final Widget child;

  const ZfoDrop({super.key, required this.child});

  @override
  State<ZfoDrop> createState() => _ZfoDropState();
}

class _ZfoDropState extends State<ZfoDrop> {
  var _over = false;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DropTarget(
      // The compose window has its own drop target for attachments.
      enable: ModalRoute.of(context)?.isCurrent ?? true,
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (d) async {
        setState(() => _over = false);
        final zfo = [
          for (final f in d.files)
            if (f.path.toLowerCase().endsWith('.zfo')) f.path,
        ];
        if (zfo.isEmpty) return;
        final messenger = ScaffoldMessenger.of(context);
        final summary = await AppScope.of(context).importZfo(zfo);
        messenger.showSnackBar(SnackBar(content: Text(summary)));
      },
      child: Stack(
        children: [
          widget.child,
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: t.accentSoft.withValues(alpha: 0.8),
                  alignment: Alignment.center,
                  child: Text(
                    'Pusťte soubory ZFO, uloží se do archivu příslušné schránky',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(color: t.accent),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
