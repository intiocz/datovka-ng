import 'package:flutter/material.dart';

import '../theme.dart';
import 'format.dart';

enum DeadlineTone { calm, soon, overdue }

DeadlineTone toneFor(DateTime deadline) {
  final left = daysUntil(deadline);
  if (left < 0) return DeadlineTone.overdue;
  if (left <= 3) return DeadlineTone.soon;
  return DeadlineTone.calm;
}

Color toneColor(Tokens t, DeadlineTone tone) => switch (tone) {
  DeadlineTone.calm => t.accent,
  DeadlineTone.soon => t.warn,
  DeadlineTone.overdue => t.danger,
};

String deadlineText(DateTime deadline) {
  final left = daysUntil(deadline);
  if (left < 0) return 'Lhůta uplynula před ${days(-left)}';
  if (left == 0) return 'Lhůta končí dnes';
  if (left == 1) return 'Lhůta končí zítra';
  return 'Zbývá ${days(left)}';
}

/// Elapsed part of the window between delivery and deadline.
class DeadlineBar extends StatelessWidget {
  final DateTime start;
  final DateTime end;
  final double height;
  final bool showLabel;

  const DeadlineBar({
    super.key,
    required this.start,
    required this.end,
    this.height = 3,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final tone = toneFor(end);
    final color = toneColor(t, tone);
    final total = end.difference(start).inMinutes;
    final elapsed = DateTime.now().difference(start).inMinutes;
    final fraction = total <= 0 ? 1.0 : (elapsed / total).clamp(0.0, 1.0);

    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: t.line)),
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
    if (!showLabel) return bar;
    return Row(
      children: [
        Expanded(child: bar),
        const SizedBox(width: 10),
        Text(
          deadlineText(end),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: tone == DeadlineTone.calm ? t.inkMuted : color,
            fontWeight: tone == DeadlineTone.calm
                ? FontWeight.w500
                : FontWeight.w700,
            fontFeatures: tabular,
          ),
        ),
      ],
    );
  }
}
