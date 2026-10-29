import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/gov_services.dart';
import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';

/// E-Government forms: requests for register printouts sent as a data
/// message to the automated boxes of the Ministry of the Interior and the
/// Basic Registers Authority (original "Služby e-Governmentu").
Future<void> showGovServices(BuildContext context) {
  final s = AppScope.of(context);
  return showDialog(
    context: context,
    builder: (_) => AppScope(state: s, child: const _GovServices()),
  );
}

class _GovServices extends StatefulWidget {
  const _GovServices();

  @override
  State<_GovServices> createState() => _GovServicesState();
}

class _GovServicesState extends State<_GovServices> {
  DataBox? _box;
  GovOwner? _owner;
  String? _ownerError;
  bool _loadingOwner = false;
  GovService? _service;
  String _filter = '';
  final Map<String, TextEditingController> _ctl = {};
  String? _error;
  bool _sending = false;

  /// Test environment boxes cannot reach the production automata.
  List<DataBox> _boxes(AppState s) =>
      s.sendingBoxes.where((b) => !b.testEnv).toList();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_box == null) {
      final s = AppScope.of(context);
      final boxes = _boxes(s);
      if (boxes.isNotEmpty) {
        final current = boxes.where((b) => b.id == s.boxId);
        _selectBox(current.isNotEmpty ? current.first : boxes.first);
      }
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _selectBox(DataBox b) async {
    final s = AppScope.of(context);
    setState(() {
      _box = b;
      _owner = null;
      _ownerError = null;
      _loadingOwner = true;
    });
    try {
      final info = await s.op(b, 'owner_info');
      if (!mounted || _box != b) return;
      setState(() => _owner = GovOwner.fromJson(info));
    } on Object catch (e) {
      if (!mounted || _box != b) return;
      setState(() => _ownerError = '$e');
    } finally {
      if (mounted && _box == b) setState(() => _loadingOwner = false);
    }
    final svc = _service;
    if (svc != null) _selectService(svc);
  }

  void _selectService(GovService svc) {
    for (final c in _ctl.values) {
      c.dispose();
    }
    _ctl.clear();
    final today = formatGovDate(DateTime.now());
    for (final f in svc.fields) {
      final initial = f.userInput
          ? (f.isDate ? today : '')
          : (_owner?.values[f.key] ?? '');
      _ctl[f.key] = TextEditingController(text: initial);
    }
    setState(() {
      _service = svc;
      _error = null;
    });
  }

  Map<String, String> get _values => {
    for (final e in _ctl.entries) e.key: e.value.text,
  };

  bool get _complete =>
      _service != null && _ctl.values.every((c) => c.text.trim().isNotEmpty);

  /// Validated and normalised values, or null with [_error] set.
  Map<String, String>? _validated() {
    final v = _values;
    final err = _service!.validate(v);
    setState(() => _error = err);
    if (err != null) return null;
    // Show the normalised values (spaces removed etc.).
    v.forEach((k, x) {
      if (_ctl[k]!.text != x) _ctl[k]!.text = x;
    });
    return v;
  }

  Future<void> _preview() async {
    final svc = _service!;
    final v = _validated();
    if (v == null) return;
    final text = Theme.of(context).textTheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Příloha ${svc.fileName}'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              svc.xml(v),
              style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final s = AppScope.of(context);
    final svc = _service!;
    final box = _box!;
    final v = _validated();
    if (v == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Odeslat žádost?'),
        content: Text(
          'Žádost: ${svc.name}\n'
          'Příjemce: ${svc.institute} (${svc.boxId})\n'
          'Odesílatel: ${box.name}\n\n'
          'Opravdu odeslat žádost do datové schránky ${svc.boxId}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Ne'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Odeslat'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final path = await svc.writeAttachment(v);
      final id = await s.send(
        from: box,
        envelope: svc.envelope(),
        files: [path],
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Žádost odeslána do schránky ${svc.institute} (${svc.boxId}) '
            'jako zpráva č. $id.',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Žádost se nepodařilo odeslat: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final boxes = _boxes(s);
    final type = _owner?.boxType;
    final q = _filter.toLowerCase();
    final services = [
      for (final g in govServices)
        if (g.canSend(type) && g.name.toLowerCase().contains(q)) g,
    ];
    return Dialog(
      child: SizedBox(
        width: 880,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Elektronická podání',
                      style: text.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zavřít',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: t.line),
            Expanded(
              child: boxes.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Žádná schránka nemůže odesílat. Přihlaste se do schránky '
                          'v produkčním prostředí nebo uložte její heslo.',
                        ),
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 320,
                          child: _list(boxes, services, t, text),
                        ),
                        VerticalDivider(width: 1, color: t.line),
                        Expanded(child: _form(t, text)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(
    List<DataBox> boxes,
    List<GovService> services,
    Tokens t,
    TextTheme text,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<DataBox>(
            initialValue: _box,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Odeslat ze schránky'),
            items: [
              for (final b in boxes)
                DropdownMenuItem(
                  value: b,
                  child: Text(
                    '${b.name} (${b.username})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _sending
                ? null
                : (b) {
                    if (b != null && b != _box) _selectBox(b);
                  },
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Hledat službu',
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 8),
          if (_loadingOwner) const LinearProgressIndicator(minHeight: 2),
          if (_ownerError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Údaje o schránce se nepodařilo načíst, údaje držitele vyplňte '
                'ručně. ($_ownerError)',
                style: text.bodySmall?.copyWith(color: t.warn),
              ),
            ),
          Expanded(
            child: services.isEmpty
                ? Center(
                    child: Text(
                      _loadingOwner
                          ? 'Načítám údaje o schránce…'
                          : 'Z této schránky nelze odeslat žádnou žádost.',
                      style: text.bodySmall,
                    ),
                  )
                : ListView(
                    children: [
                      for (final g in services)
                        ListTile(
                          dense: true,
                          selected: g == _service,
                          selectedTileColor: t.accentSoft,
                          title: Text(g.name),
                          subtitle: Text(g.institute),
                          onTap: _sending ? null : () => _selectService(g),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _form(Tokens t, TextTheme text) {
    final svc = _service;
    if (svc == null) {
      return Center(
        child: Text('Vyberte službu ze seznamu.', style: text.bodyMedium),
      );
    }
    final ownerKnown = _owner != null;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(svc.name, style: text.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Příjemce: ${svc.boxId} – ${svc.institute}\n'
          'Předmět: ${svc.annotation}\n'
          'Příloha: ${svc.fileName}',
          style: text.bodySmall?.copyWith(color: t.inkMuted),
        ),
        const SizedBox(height: 16),
        if (svc.fields.isEmpty)
          const Text('Žádné údaje není třeba vyplňovat.')
        else
          for (final f in svc.fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _field(f, editable: f.userInput || !ownerKnown),
            ),
        if (svc.needsOwnerInfo && ownerKnown)
          Text(
            'Údaje držitele schránky jsou převzaty z informací o schránce.',
            style: text.bodySmall?.copyWith(color: t.inkMuted),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: t.danger)),
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: _complete && !_sending ? _preview : null,
              icon: const Icon(Icons.code, size: 18),
              label: const Text('Náhled přílohy'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _complete && !_sending && _box != null ? _send : null,
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send, size: 18),
              label: const Text('Odeslat žádost'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _field(GovField f, {required bool editable}) {
    final c = _ctl[f.key]!;
    final label = f.label;
    if (f.isDate && f.userInput) {
      return TextField(
        controller: c,
        readOnly: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: f.placeholder.isEmpty ? null : f.placeholder,
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        onTap: () async {
          final now = DateTime.now();
          final picked = await showDatePicker(
            context: context,
            initialDate: parseGovDate(c.text) ?? now,
            firstDate: DateTime(1900),
            lastDate: now,
          );
          if (picked != null) {
            setState(() {
              c.text = formatGovDate(picked);
              _error = null;
            });
          }
        },
      );
    }
    return TextField(
      controller: c,
      enabled: editable && !_sending,
      decoration: InputDecoration(
        labelText: label,
        hintText: f.placeholder.isEmpty
            ? (f.isDate ? 'rrrr-mm-dd' : null)
            : f.placeholder,
      ),
      onChanged: (_) => setState(() => _error = null),
    );
  }
}
