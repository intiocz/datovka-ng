import 'package:flutter/material.dart';

import '../data/updates.dart';

/// What a new version brings, as bullet points with `**bold**` shown bold.
class ReleaseNotes extends StatelessWidget {
  final String notes;
  final TextStyle? style;
  const ReleaseNotes(this.notes, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final base = style ?? Theme.of(context).textTheme.bodyMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final point in releaseNews(notes))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: base),
                Expanded(child: Text.rich(_spans(point), style: base)),
              ],
            ),
          ),
      ],
    );
  }

  static TextSpan _spans(String point) {
    final parts = point.split('**');
    return TextSpan(
      children: [
        for (var i = 0; i < parts.length; i++)
          if (parts[i].isNotEmpty)
            TextSpan(
              text: parts[i].replaceAll('`', ''),
              style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w600) : null,
            ),
      ],
    );
  }
}
