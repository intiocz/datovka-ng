import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import 'app_scope.dart';

/// Settings of the records management service ("spisová služba"): URL,
/// access token and a connection test showing the service info.
Future<void> showRecordsSettings(BuildContext context) {
  final s = AppScope.of(context);
  return showDialog(
    context: context,
    builder: (_) => _RecordsSettingsDialog(state: s),
  );
}

class _RecordsSettingsDialog extends StatefulWidget {
  final AppState state;

  const _RecordsSettingsDialog({required this.state});

  @override
  State<_RecordsSettingsDialog> createState() => _RecordsSettingsDialogState();
}

class _RecordsSettingsDialogState extends State<_RecordsSettingsDialog> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _hasToken = false;
  bool _busy = false;
  Map<String, dynamic>? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    try {
      final st = widget.state.recordsSettings();
      _url.text = '${st['url'] ?? ''}';
      _hasToken = st['configured'] == true;
    } on Object catch (e) {
      _error = '$e';
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  bool _save() {
    try {
      widget.state.saveRecordsSettings(_url.text, _token.text);
      _hasToken = _url.text.trim().isNotEmpty;
      _token.clear();
      return true;
    } on Object catch (e) {
      setState(() => _error = '$e');
      return false;
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    // The test uses the saved settings, as the core never returns the token.
    if (_save()) {
      try {
        final info = await widget.state.recordsServiceInfo();
        if (mounted) setState(() => _info = info);
      } on Object catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final info = _info;
    return AlertDialog(
      title: const Text('Spisová služba'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Zprávy lze ukládat do spisové služby, která podporuje rozhraní '
              'Datovky. Adresu a přístupový token získáte od jejího správce.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Adresa služby (URL)',
                hintText: 'https://spisovka.example.cz/api/',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _token,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Přístupový token',
                helperText: _hasToken
                    ? 'Token je uložen; vyplňte jen pro změnu.'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Flexible(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _test,
                    child: const Text(
                      'Uložit a otestovat spojení',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            if (info != null) ...[
              const SizedBox(height: 12),
              Text('Název služby: ${info['name']}', style: text.bodyMedium),
              Text(
                'Token patří: ${info['token_name']}',
                style: text.bodyMedium,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: text.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  if (_save()) Navigator.pop(context);
                },
          child: const Text('Uložit'),
        ),
      ],
    );
  }
}

/// Lets the user pick locations in the service's upload hierarchy and
/// uploads the signed message there.
Future<void> showRecordsUpload(BuildContext context, Message m) async {
  final s = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final ids = await showDialog<List<String>>(
    context: context,
    builder: (_) => _UploadDialog(state: s, message: m),
  );
  if (ids == null || ids.isEmpty) return;
  try {
    final locations = await s.uploadToRecords(m, ids);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          'Zpráva ${m.dmId} uložena do spisové služby'
          '${locations.isEmpty ? '' : ':\n${locations.join('\n')}'}',
        ),
      ),
    );
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Uložení do spisové služby selhalo: $e')),
    );
  }
}

class _UploadDialog extends StatefulWidget {
  final AppState state;
  final Message message;

  const _UploadDialog({required this.state, required this.message});

  @override
  State<_UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends State<_UploadDialog> {
  late final Future<Map<String, dynamic>> _root = widget.state
      .recordsHierarchy();
  final Set<String> _selected = {};
  String _filter = '';

  /// True when the node or one of its descendants matches the filter
  /// (name or metadata), as `UploadHierarchyProxyModel` does.
  bool _matches(Map node) {
    if (_filter.isEmpty) return true;
    final f = _filter.toLowerCase();
    final own = [
      '${node['name'] ?? ''}',
      ...((node['metadata'] as List?) ?? const []).map((e) => '$e'),
    ].any((v) => v.toLowerCase().contains(f));
    return own || _subs(node).any(_matches);
  }

  List<Map> _subs(Map node) => ((node['sub'] as List?) ?? const []).cast<Map>();

  List<Widget> _nodes(Map node, int depth) {
    final out = <Widget>[];
    for (final sub in _subs(node)) {
      if (!_matches(sub)) continue;
      final id = sub['id'] as String?;
      final selectable = id != null && id.isNotEmpty;
      final meta = ((sub['metadata'] as List?) ?? const [])
          .map((e) => '$e')
          .where((e) => e.isNotEmpty && e != sub['name'])
          .join(', ');
      out.add(
        Padding(
          padding: EdgeInsets.only(left: 20.0 * depth),
          child: selectable
              ? CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selected.contains(id),
                  title: Text('${sub['name']}'),
                  subtitle: meta.isEmpty ? null : Text(meta),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(id);
                    } else {
                      _selected.remove(id);
                    }
                  }),
                )
              : ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text('${sub['name']}'),
                  subtitle: meta.isEmpty ? null : Text(meta),
                ),
        ),
      );
      out.addAll(_nodes(sub, depth + 1));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Uložit zprávu ${widget.message.dmId} do spisové služby'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _root,
          builder: (context, snap) {
            if (snap.hasError) {
              return Text(
                '${snap.error}',
                style: text.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              );
            }
            final root = snap.data;
            if (root == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final nodes = _nodes(root, 0);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Vyberte jedno nebo více umístění:',
                  style: text.bodySmall,
                ),
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Filtrovat podle názvu nebo spisové značky',
                  ),
                  onChanged: (v) => setState(() => _filter = v.trim()),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: nodes.isEmpty
                      ? Text('Žádné umístění.', style: text.bodySmall)
                      : ListView(children: nodes),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: const Text('Nahrát'),
        ),
      ],
    );
  }
}
