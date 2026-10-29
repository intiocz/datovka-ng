import 'dart:async';
import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';

typedef Recipient = ({String boxId, String name});

/// Pre-filled values for a new message (reply, forward, draft, found box).
class Draft {
  final int? draftId;
  final String? fromBoxId;
  final List<Recipient> recipients;
  final String subject;
  final String? senderRef;
  final String? recipientRef;
  final String? toHands;
  final List<String> files;

  /// `I` initiating commercial message, `O` reply to one, `K` contract, null ordinary.
  final String? dmType;

  const Draft({
    this.draftId,
    this.fromBoxId,
    this.recipients = const [],
    this.subject = '',
    this.senderRef,
    this.recipientRef,
    this.toHands,
    this.files = const [],
    this.dmType,
  });

  /// One recipient given by box ID and display name.
  factory Draft.to(String boxId, String name) =>
      Draft(recipients: [(boxId: boxId, name: name)]);

  /// Reply to a received message: back to its sender, references swapped.
  factory Draft.reply(Message m) => Draft(
    fromBoxId: m.boxId,
    recipients: [
      if (m.counterpartyBoxId != null)
        (boxId: m.counterpartyBoxId!, name: m.counterparty),
    ],
    subject: m.subject.startsWith('Re: ') ? m.subject : 'Re: ${m.subject}',
    senderRef: m.ourRef,
    recipientRef: m.theirRef,
  );

  factory Draft.fromJson(int id, Map<String, dynamic> j) => Draft(
    draftId: id,
    fromBoxId: j['from'] as String?,
    recipients: [
      for (final r in (j['recipients'] as List? ?? const []))
        (
          boxId: (r as Map)['boxId'] as String,
          name: r['name'] as String? ?? '',
        ),
    ],
    subject: j['subject'] as String? ?? '',
    senderRef: j['senderRef'] as String?,
    recipientRef: j['recipientRef'] as String?,
    toHands: j['toHands'] as String?,
    files: (j['files'] as List? ?? const []).cast<String>(),
    dmType: j['dmType'] as String?,
  );
}

Future<void> showCompose(BuildContext context, [Draft draft = const Draft()]) {
  final state = AppScope.of(context);
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AppScope(
        state: state,
        child: _Compose(draft: draft),
      ),
    ),
  );
}

class _Compose extends StatefulWidget {
  final Draft draft;

  const _Compose({required this.draft});

  @override
  State<_Compose> createState() => _ComposeState();
}

class _ComposeState extends State<_Compose> {
  late final _subject = TextEditingController(text: widget.draft.subject);
  late final _senderRef = TextEditingController(
    text: widget.draft.senderRef ?? '',
  );
  late final _recipientRef = TextEditingController(
    text: widget.draft.recipientRef ?? '',
  );
  late final _toHands = TextEditingController(text: widget.draft.toHands ?? '');
  final _lookup = TextEditingController();
  final _legal = List.generate(5, (_) => TextEditingController());
  late final _recipients = [...widget.draft.recipients];
  late final _files = <XFile>[for (final f in widget.draft.files) XFile(f)];
  late String? _dmType = widget.draft.dmType;
  late int? _draftId = widget.draft.draftId;
  var _personal = false;
  var _fiction = true;
  var _publishId = false;
  var _more = false;
  var _dragging = false;
  var _sending = false;
  String? _error;
  DataBox? _from;
  Timer? _debounce;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_from == null) {
      final s = AppScope.of(context);
      final boxes = s.sendingBoxes;
      _from =
          boxes.where((b) => b.id == widget.draft.fromBoxId).firstOrNull ??
          boxes.where((b) => b.id == s.boxId).firstOrNull ??
          boxes.firstOrNull;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [
      _subject,
      _senderRef,
      _recipientRef,
      _toHands,
      _lookup,
      ..._legal,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _opt(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Map<String, Object?> _envelope(String recipient) => {
    'recipient_box_id': recipient,
    'annotation': _subject.text.trim(),
    'to_hands': _opt(_toHands),
    'sender_ref_number': _opt(_senderRef),
    'recipient_ref_number': _opt(_recipientRef),
    'personal_delivery': _personal,
    'allow_subst_delivery': _fiction,
    'publish_own_id': _publishId ? true : null,
    'dm_type': _dmType,
    'legal_title_law': _opt(_legal[0]),
    'legal_title_year': _opt(_legal[1]),
    'legal_title_sect': _opt(_legal[2]),
    'legal_title_par': _opt(_legal[3]),
    'legal_title_point': _opt(_legal[4]),
  };

  void _addRecipient(String boxId, String name) {
    final id = boxId.trim();
    if (id.length != 7 || _recipients.any((r) => r.boxId == id)) return;
    setState(() {
      _recipients.add((boxId: id, name: name));
      _lookup.clear();
      AppScope.of(context).directoryResults = null;
    });
  }

  void _onLookup(String q) {
    final s = AppScope.of(context);
    final t = q.trim();
    setState(() {});
    _debounce?.cancel();
    // A box ID is added with Enter, no need to search.
    if (RegExp(r'^[a-z0-9]{7}$').hasMatch(t)) return;
    _debounce = Timer(const Duration(milliseconds: 300), () {
      s.directoryScope = RegExp(r'^\d{8}$').hasMatch(t)
          ? DirectoryScope.ico
          : DirectoryScope.general;
      s.searchDirectory(t);
    });
  }

  Future<void> _saveDraft() async {
    final s = AppScope.of(context);
    final from = _from ?? s.boxes.firstOrNull;
    if (from == null) return;
    final content = jsonEncode({
      'from': from.id,
      'recipients': [
        for (final r in _recipients) {'boxId': r.boxId, 'name': r.name},
      ],
      'subject': _subject.text,
      'senderRef': _opt(_senderRef),
      'recipientRef': _opt(_recipientRef),
      'toHands': _opt(_toHands),
      'files': [for (final f in _files) f.path],
      'dmType': _dmType,
    });
    try {
      _draftId = s.saveDraft(from, _draftId, content);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Koncept uložen')));
      }
    } on Object catch (e) {
      setState(() => _error = 'Koncept se nepodařilo uložit: $e');
    }
  }

  static String _who(Recipient r) => r.name.isEmpty ? r.boxId : r.name;

  Future<void> _send() async {
    final s = AppScope.of(context);
    final from = _from;
    final problems = [
      if (from == null) 'vyberte odesílající schránku',
      if (_recipients.isEmpty) 'přidejte adresáta',
      if (_subject.text.trim().isEmpty) 'vyplňte věc',
      if (_files.isEmpty) 'přidejte aspoň jeden dokument',
    ];
    if (problems.isNotEmpty) {
      setState(() => _error = 'Nelze odeslat: ${problems.join(', ')}.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final sent = <String>[];
    final failed = <Recipient, String>{};
    for (final r in _recipients) {
      try {
        final id = await s.send(
          from: from!,
          envelope: _envelope(r.boxId),
          files: [for (final f in _files) f.path],
        );
        sent.add('${_who(r)}: $id');
      } on Object catch (e) {
        failed[r] = '$e';
      }
    }
    unawaited(s.runSync());
    if (!mounted) return;
    if (failed.isEmpty) {
      if (_draftId != null) s.deleteDraft(_draftId!);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(content: Text('Odesláno – ${sent.join(', ')}')),
      );
    } else {
      setState(() {
        _sending = false;
        // Keep only recipients that failed, so a retry does not send twice.
        _recipients.removeWhere((r) => !failed.containsKey(r));
        _error = [
          if (sent.isNotEmpty) 'Odesláno: ${sent.join(', ')}.',
          'Neodesláno: ${failed.entries.map((e) => '${_who(e.key)}: ${e.value}').join('; ')}',
        ].join('\n');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final boxes = s.sendingBoxes;
    final q = _lookup.text.trim().toLowerCase();
    final contactHits = q.length < 2
        ? const <Contact>[]
        : s.contactsMatching(q).take(5).toList();
    final isdsHits = q.length >= 3
        ? (s.directoryResults ?? const <DirectoryEntry>[])
        : const <DirectoryEntry>[];

    Widget field(
      String label,
      TextEditingController c, {
      int maxLength = 255,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        maxLength: maxLength,
        decoration: InputDecoration(labelText: label, counterText: ''),
      ),
    );

    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _error!,
              style: text.bodySmall?.copyWith(color: t.danger),
            ),
          ),
        if (boxes.isEmpty)
          Text(
            'Žádná schránka není přihlášená. Přihlaste se (klíček u schránky), nebo uložte koncept.',
            style: text.bodySmall?.copyWith(color: t.warn),
          )
        else
          DropdownButtonFormField<DataBox>(
            initialValue: _from,
            decoration: const InputDecoration(labelText: 'Od'),
            items: [
              for (final b in boxes)
                DropdownMenuItem(
                  value: b,
                  child: Text('${b.name} (${b.isdsId ?? b.id})'),
                ),
            ],
            onChanged: (b) => setState(() => _from = b),
          ),
        const SizedBox(height: 16),
        Text('Komu', style: text.bodySmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final r in _recipients)
              InputChip(
                label: Text(
                  r.name.isEmpty ? r.boxId : '${r.name} (${r.boxId})',
                ),
                onDeleted: () => setState(() => _recipients.remove(r)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _lookup,
          decoration: InputDecoration(
            hintText: 'ID schránky (Enter), nebo název či IČO adresáta',
            hintStyle: text.bodyMedium?.copyWith(color: t.inkMuted),
            prefixIcon: Icon(Icons.person_add_alt, size: 20, color: t.inkMuted),
            suffixIcon: s.directoryBusy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onChanged: _onLookup,
          onSubmitted: (v) => _addRecipient(v, ''),
        ),
        if (contactHits.isNotEmpty || isdsHits.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              border: Border.all(color: t.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in contactHits)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.history, size: 18, color: t.inkMuted),
                    title: Text(c.name),
                    subtitle: Text('${c.boxId}, ${c.address}'),
                    onTap: () => _addRecipient(c.boxId, c.name),
                  ),
                for (final e in isdsHits)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.travel_explore,
                      size: 18,
                      color: t.inkMuted,
                    ),
                    title: Text(e.name),
                    subtitle: Text('${e.boxId}, ${e.address}'),
                    onTap: () => _addRecipient(e.boxId, e.name),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        field('Věc', _subject),
        Row(
          children: [
            Expanded(child: field('Naše č. j.', _senderRef, maxLength: 50)),
            const SizedBox(width: 12),
            Expanded(child: field('Vaše č. j.', _recipientRef, maxLength: 50)),
          ],
        ),
        field('K rukám', _toHands, maxLength: 50),
        Wrap(
          spacing: 16,
          children: [
            _Check(
              'Do vlastních rukou',
              _personal,
              (v) => setState(() => _personal = v),
            ),
            _Check(
              'Povolit doručení fikcí',
              _fiction,
              (v) => setState(() => _fiction = v),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _more = !_more),
            icon: Icon(_more ? Icons.expand_less : Icons.expand_more, size: 18),
            label: const Text('Další volby'),
          ),
        ),
        if (_more) ...[
          DropdownButtonFormField<String?>(
            initialValue: _dmType,
            decoration: const InputDecoration(labelText: 'Typ zprávy'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Běžná zpráva')),
              DropdownMenuItem(
                value: 'I',
                child: Text('Iniciační poštovní zpráva (odpověď platíte vy)'),
              ),
              DropdownMenuItem(
                value: 'O',
                child: Text('Odpověď na iniciační poštovní zprávu'),
              ),
              DropdownMenuItem(
                value: 'K',
                child: Text('Poštovní zpráva na základě smlouvy'),
              ),
            ],
            onChanged: (v) => setState(() => _dmType = v),
          ),
          const SizedBox(height: 8),
          _Check(
            'Zveřejnit mou identitu adresátovi',
            _publishId,
            (v) => setState(() => _publishId = v),
          ),
          const SizedBox(height: 8),
          Text('Zmocnění', style: text.bodySmall),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (i, l) in [
                'Zákon č.',
                'Rok',
                '§',
                'Odst.',
                'Písm.',
              ].indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: field(l, _legal[i], maxLength: 10)),
              ],
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text('Dokumenty', style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          'První dokument bude hlavní písemností zprávy.',
          style: text.bodySmall?.copyWith(color: t.inkMuted),
        ),
        const SizedBox(height: 12),
        for (final (i, f) in _files.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              i == 0 ? Icons.description : Icons.attach_file,
              color: t.inkMuted,
            ),
            title: Text(f.name),
            subtitle: i == 0
                ? Text('Hlavní dokument', style: text.bodySmall)
                : null,
            trailing: IconButton(
              tooltip: 'Odebrat',
              onPressed: () => setState(() => _files.removeAt(i)),
              icon: const Icon(Icons.close, size: 18),
            ),
          ),
        const SizedBox(height: 8),
        FileDropZone(
          active: _dragging,
          compact: _files.isNotEmpty,
          onPick: () async {
            final picked = await openFiles();
            if (picked.isNotEmpty) setState(() => _files.addAll(picked));
          },
        ),
      ],
    );

    return Scaffold(
      backgroundColor: t.surface,
      appBar: AppBar(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        title: Text(
          widget.draft.subject.startsWith('Re: ') ? 'Odpověď' : 'Nová zpráva',
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : _saveDraft,
            child: const Text('Uložit koncept'),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send, size: 18),
              label: Text(_sending ? 'Odesílám…' : 'Odeslat'),
            ),
          ),
        ],
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) => setState(() {
          _dragging = false;
          _files.addAll(d.files.where((f) => f.path.isNotEmpty));
        }),
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: form,
                ),
              ),
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.accentSoft.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.accent, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Pusťte soubory sem, přidají se ke zprávě',
                      style: text.titleMedium?.copyWith(color: t.accent),
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

/// Dashed area for documents: click opens the file picker, files dragged
/// anywhere over the window land here. [compact] once something is attached.
class FileDropZone extends StatefulWidget {
  final bool active;
  final bool compact;
  final VoidCallback onPick;

  const FileDropZone({
    super.key,
    required this.active,
    required this.compact,
    required this.onPick,
  });

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final lit = widget.active || _hover;
    final body = text.bodyMedium?.copyWith(color: t.ink);
    final link = body?.copyWith(
      color: t.accent,
      decoration: TextDecoration.underline,
      decorationColor: t.accent,
    );
    final label = widget.active
        ? Text('Pusťte soubory, přidají se ke zprávě', style: link)
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: widget.compact
                      ? 'Přidat další soubory'
                      : 'Vyberte soubory',
                  style: link,
                ),
                const TextSpan(text: ' nebo je přetáhněte sem'),
              ],
            ),
            style: body,
            textAlign: TextAlign.center,
          );
    return Semantics(
      button: true,
      label: 'Vyberte soubory nebo je přetáhněte sem',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPick,
          child: CustomPaint(
            painter: _DashedBorder(
              color: lit ? t.accent : t.inkMuted.withValues(alpha: 0.45),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: widget.compact ? 14 : 32,
              ),
              decoration: BoxDecoration(
                color: lit ? t.accent.withValues(alpha: 0.06) : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: widget.compact
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.file_upload_outlined,
                          size: 20,
                          color: lit ? t.accent : t.inkMuted,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: label),
                      ],
                    )
                  : Column(
                      children: [
                        Icon(
                          Icons.file_upload_outlined,
                          size: 30,
                          color: lit ? t.accent : t.inkMuted,
                        ),
                        const SizedBox(height: 12),
                        label,
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  final Color color;

  const _DashedBorder({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(8),
        ).deflate(0.5),
      );
    for (final m in outline.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 8) {
        canvas.drawPath(m.extractPath(d, d + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

class _Check extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _Check(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}

/// Saved drafts shown in place of the message list; opening one continues
/// writing it. Empty folder shows nothing.
class DraftList extends StatefulWidget {
  /// Only drafts written from this box; null shows all.
  final String? boxId;

  const DraftList({super.key, this.boxId});

  @override
  State<DraftList> createState() => _DraftListState();
}

class _DraftListState extends State<DraftList> {
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final drafts = [
      for (final d in s.drafts())
        Draft.fromJson(
          d['id'] as int,
          jsonDecode(d['content'] as String) as Map<String, dynamic>,
        ),
    ].where((d) => widget.boxId == null || d.fromBoxId == widget.boxId);
    return ListView(
      children: [
        for (final draft in drafts) ...[
          ListTile(
            title: Text(draft.subject.isEmpty ? '(bez věci)' : draft.subject),
            subtitle: Text(
              draft.recipients
                  .map((r) => r.name.isEmpty ? r.boxId : r.name)
                  .join(', '),
            ),
            onTap: () async {
              await showCompose(context, draft);
              if (mounted) setState(() {});
            },
            trailing: IconButton(
              tooltip: 'Smazat koncept',
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                s.deleteDraft(draft.draftId!);
                setState(() {});
              },
            ),
          ),
          Divider(height: 1, indent: 20, color: t.line),
        ],
      ],
    );
  }
}
