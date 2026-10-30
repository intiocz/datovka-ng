import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';
import 'ai_dialog.dart';
import 'compose.dart';
import 'signature_view.dart';
import 'envelope_pdf.dart';
import 'message_actions.dart';
import 'pdf_view.dart';
import 'deadline.dart';
import 'format.dart';

class MessageDetail extends StatelessWidget {
  final Message m;
  final bool showBack;

  const MessageDetail({super.key, required this.m, this.showBack = false});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final box = s.boxById(m.boxId);
    final received = m.direction == Direction.received;

    return Container(
      color: t.surface,
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(m: m, showBack: showBack),
            Divider(height: 1, color: t.line),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 40),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (m.suspicious) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: t.danger.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.report_outlined, color: t.danger),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'ISDS označil tuto zprávu jako podezřelou '
                                    '(nevyžádaná nebo škodlivá). Přílohy '
                                    'otevírejte opatrně.',
                                    style: text.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          m.subject,
                          style: text.headlineSmall?.copyWith(fontSize: 24),
                        ),
                        const SizedBox(height: 18),
                        _Party(
                          label: received ? 'Od' : 'Komu',
                          name: m.counterparty,
                          address: m.counterpartyAddress,
                        ),
                        const SizedBox(height: 10),
                        _Party(
                          label: received ? 'Komu' : 'Od',
                          name: box?.name ?? m.boxId,
                          address: 'Schránka ${m.boxId}',
                        ),
                        const SizedBox(height: 22),
                        FutureBuilder<Map<String, dynamic>?>(
                          future: s.signatureOf(m),
                          builder: (context, snap) {
                            final r = snap.data;
                            return InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: r == null
                                  ? null
                                  : () => showSignatureReport(context, r),
                              child: _Seal(
                                valid: r == null
                                    ? m.signatureValid
                                    : signatureOk(r),
                                deletion: m.isdsDeletion,
                                checked: r != null,
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 26),
                        _DeadlineSection(m: m),
                        const SizedBox(height: 20),
                        _Tags(m: m),
                        const SizedBox(height: 20),
                        _Note(m: m),
                        const SizedBox(height: 28),
                        Row(
                          children: [
                            Expanded(
                              child: Text('Přílohy', style: text.titleMedium),
                            ),
                            TextButton.icon(
                              onPressed: () => showAiAnalysis(context, m),
                              icon: const Icon(Icons.auto_awesome, size: 18),
                              label: const Text('Najít termíny (AI)'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _Attachments(m: m),
                        const SizedBox(height: 28),
                        Text('Údaje zprávy', style: text.titleMedium),
                        const SizedBox(height: 10),
                        _Facts(
                          rows: [
                            // Dodání into the box, then doručení (the
                            // recipient logged in, or by fiction).
                            ('Dodáno', longDate(m.delivered)),
                            if (m.accepted != null)
                              ('Doručeno', longDate(m.accepted!))
                            else if (!received)
                              ('Doručeno', 'zatím ne'),
                            ('ID zprávy', m.dmId),
                            if (m.theirRef != null)
                              ('Č. j. odesílatele', m.theirRef!),
                            if (m.ourRef != null) ('Naše č. j.', m.ourRef!),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final Message m;
  final bool showBack;

  const _Toolbar({required this.m, required this.showBack});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              tooltip: 'Zpět',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
          // A narrow detail (an iPad pane, larger text) scrolls the buttons
          // rather than overflowing.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m.direction == Direction.received)
                      FilledButton.icon(
                        onPressed: () => showCompose(context, Draft.reply(m)),
                        icon: const Icon(Icons.reply, size: 18),
                        label: const Text('Odpovědět'),
                        style: FilledButton.styleFrom(
                          backgroundColor: t.accent,
                        ),
                      ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: m.isRead
                          ? 'Označit jako nepřečtené'
                          : 'Označit jako přečtené',
                      onPressed: () => s.toggleRead(m.dmId),
                      icon: Icon(
                        m.isRead
                            ? Icons.mark_email_unread_outlined
                            : Icons.mark_email_read_outlined,
                        color: t.inkMuted,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Uložit podepsanou zprávu (ZFO)',
                      onPressed: () => saveSignedFile(context, m),
                      icon: Icon(
                        Icons.file_download_outlined,
                        color: t.inkMuted,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Vytisknout nebo uložit obálku do PDF',
                      onPressed: () => printEnvelope(context, m),
                      icon: Icon(Icons.print_outlined, color: t.inkMuted),
                    ),
                    MessageActions(m: m),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Party extends StatelessWidget {
  final String label;
  final String name;
  final String address;

  const _Party({
    required this.label,
    required this.name,
    required this.address,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 56, child: Text(label, style: text.bodySmall)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(address, style: text.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// Signature and archive status: the two things that make the message legally usable.
class _Seal extends StatelessWidget {
  /// `null` when the signature has not been checked yet.
  final bool? valid;
  final DateTime deletion;

  /// The signature was verified locally; tap shows details.
  final bool checked;

  const _Seal({
    required this.valid,
    required this.deletion,
    this.checked = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final color = switch (valid) {
      true => t.ok,
      false => t.danger,
      null => t.accent,
    };
    final left = daysUntil(deletion);
    final archive = left > 0
        ? 'Originál je uložený v archivu. Z ISDS zmizí za ${days(left)} (${dayDate(deletion)}).'
        : 'Originál je uložený v archivu. V ISDS už zpráva není.';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        color: color.withValues(alpha: 0.06),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            switch (valid) {
              true => Icons.verified_outlined,
              false => Icons.gpp_bad_outlined,
              null => Icons.inventory_2_outlined,
            },
            color: color,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (valid) {
                    true => 'Podpis i časové razítko jsou platné',
                    false => 'Podpis nebo časové razítko nejsou v pořádku',
                    null => 'Podepsaný originál je uložený',
                  },
                  style: text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(archive, style: text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeadlineSection extends StatelessWidget {
  final Message m;

  const _DeadlineSection({required this.m});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;

    void setDays(int d) =>
        s.setDeadline(m.dmId, DateTime.now().add(Duration(days: d)));

    Future<void> pick() async {
      final d = await showDatePicker(
        context: context,
        initialDate: m.deadline ?? DateTime.now().add(const Duration(days: 15)),
        firstDate: DateTime.now().subtract(const Duration(days: 365)),
        lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
        helpText: 'Lhůta pro reakci',
      );
      if (d != null) s.setDeadline(m.dmId, d);
    }

    if (m.deadline == null) {
      return Row(
        children: [
          Text('Lhůta', style: text.titleMedium),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in [8, 15, 30])
                  OutlinedButton(
                    onPressed: () => setDays(d),
                    child: Text(days(d)),
                  ),
                TextButton(onPressed: pick, child: const Text('Vybrat datum')),
              ],
            ),
          ),
        ],
      );
    }

    final tone = toneFor(m.deadline!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Lhůta do ${dayDate(m.deadline!)}',
                style: text.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: pick, child: const Text('Změnit')),
            TextButton(
              onPressed: () => s.setDeadline(m.dmId, null),
              style: TextButton.styleFrom(foregroundColor: t.inkMuted),
              child: const Text('Splněno'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DeadlineBar(start: m.delivered, end: m.deadline!, height: 6),
        if (tone == DeadlineTone.overdue) ...[
          const SizedBox(height: 8),
          Text(
            'Pokud je vyřízeno, označte lhůtu jako splněnou.',
            style: text.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _Attachments extends StatefulWidget {
  final Message m;

  const _Attachments({required this.m});

  @override
  State<_Attachments> createState() => _AttachmentsState();
}

class _AttachmentsState extends State<_Attachments> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context).loadAttachments(widget.m);
  }

  @override
  void didUpdateWidget(_Attachments old) {
    super.didUpdateWidget(old);
    if (old.m.dmId != widget.m.dmId) {
      AppScope.of(context).loadAttachments(widget.m);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Column(
      children: [
        for (final a in s.attachmentsOf(widget.m))
          _AttachmentRow(m: widget.m, a: a),
      ],
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  final Message m;
  final Attachment a;

  const _AttachmentRow({required this.m, required this.a});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final ext = a.name.contains('.')
        ? a.name.split('.').last.toUpperCase()
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => isPdf(a)
            ? showPdf(context, m, a)
            : AppScope.of(context).openAttachment(m, a),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.line),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.accentSoft,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  ext,
                  style: text.bodySmall?.copyWith(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: t.accent,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium,
                ),
              ),
              Text(
                fileSize(a.sizeBytes),
                style: text.bodySmall?.copyWith(fontFeatures: tabular),
              ),
              const SizedBox(width: 6),
              Icon(Icons.open_in_new, size: 16, color: t.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  final List<(String, String)> rows;

  const _Facts({required this.rows});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // On a phone the label goes above the value, as in InfoView.
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 440;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Flex(
                  direction: narrow ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (narrow)
                      Text(
                        k,
                        style: text.bodySmall?.copyWith(
                          color: Tokens.of(context).inkMuted,
                        ),
                      )
                    else
                      SizedBox(
                        width: 150,
                        child: Text(k, style: text.bodySmall),
                      ),
                    if (narrow)
                      SelectableText(
                        v,
                        style: text.bodyMedium?.copyWith(fontFeatures: tabular),
                      )
                    else
                      Expanded(
                        child: SelectableText(
                          v,
                          style: text.bodyMedium?.copyWith(
                            fontFeatures: tabular,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Shown in the detail pane when nothing is selected.
class NoSelection extends StatelessWidget {
  const NoSelection({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final s = AppScope.of(context);
    final unread = s.unreadIn(s.boxId);
    return Container(
      color: t.surface,
      alignment: Alignment.center,
      child: Text(
        unread > 0
            ? 'Nepřečtené zprávy: $unread. Vyberte zprávu vlevo.'
            : 'Vyberte zprávu vlevo.',
        style: text.bodySmall,
      ),
    );
  }
}

/// The note of the message: shown when there is one, otherwise a button.
class _Note extends StatelessWidget {
  final Message m;

  const _Note({required this.m});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final note = m.note;
    if (note == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => editNote(context, m),
          icon: Icon(Icons.sticky_note_2_outlined, size: 18, color: t.accent),
          label: const Text('Přidat poznámku'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Poznámka', style: text.titleMedium)),
            IconButton(
              tooltip: 'Upravit poznámku',
              onPressed: () => editNote(context, m),
              icon: Icon(Icons.edit_outlined, size: 18, color: t.inkMuted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => editNote(context, m),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.warn.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.warn.withValues(alpha: 0.25)),
            ),
            child: Text(note, style: text.bodyMedium),
          ),
        ),
      ],
    );
  }
}

class _Tags extends StatelessWidget {
  final Message m;

  const _Tags({required this.m});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Štítky', style: text.titleMedium),
        const SizedBox(width: 8),
        for (final tag in m.tags)
          InputChip(
            label: Text(tag),
            onDeleted: () => s.setTag(m, tag, false),
            deleteButtonTooltipMessage: 'Odebrat štítek',
          ),
        ActionChip(
          avatar: Icon(Icons.add, size: 16, color: t.accent),
          label: const Text('Přidat štítek'),
          onPressed: () async {
            final tag = await _askTag(
              context,
              s.allTags.where((x) => !m.tags.contains(x)).toList(),
            );
            if (tag != null && tag.trim().isNotEmpty) {
              s.setTag(m, tag.trim(), true);
            }
          },
        ),
      ],
    );
  }

  Future<String?> _askTag(BuildContext context, List<String> existing) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Přidat štítek'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Název štítku'),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              if (existing.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in existing)
                      ActionChip(
                        label: Text(e),
                        onPressed: () => Navigator.pop(ctx, e),
                      ),
                  ],
                ),
              ],
            ],
          ),
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
}
