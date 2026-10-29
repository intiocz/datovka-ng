import 'dart:io';

import 'package:flutter/material.dart';

import '../data/ai.dart';
import '../theme.dart';

/// Picks how the assistant is connected. One at a time.
Future<void> showConnectAssistant(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) => const _ConnectDialog(),
  );
}

class _Card {
  final AssistantKind kind;
  final IconData icon;
  final String title;
  final String subtitle;

  const _Card(this.kind, this.icon, this.title, this.subtitle);
}

const _cards = [
  _Card(
    AssistantKind.local,
    Icons.laptop_mac_outlined,
    'Model v počítači',
    'Ollama, LM Studio',
  ),
  _Card(
    AssistantKind.api,
    Icons.key_outlined,
    'API klíč',
    'Claude, OpenAI…',
  ),
  _Card(
    AssistantKind.subscription,
    Icons.workspace_premium_outlined,
    'Předplatné',
    'Claude Pro, ChatGPT',
  ),
  _Card(
    AssistantKind.other,
    Icons.extension_outlined,
    'Jiná aplikace (MCP)',
    'Cursor, editory',
  ),
  _Card(
    AssistantKind.none,
    Icons.lock_outline,
    'Bez asistenta',
    'jen pravidla',
  ),
];

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog();

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  AssistantKind _kind = AssistantKind.none;
  var _ready = false;
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  var _provider = 'claude';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kind = await AssistantPrefs.kind();
    final url = await AssistantPrefs.endpoint();
    final model = await AssistantPrefs.model(fallback: '');
    final provider = await AssistantPrefs.apiProvider();
    if (!mounted) return;
    setState(() {
      _kind = kind;
      _url.text = url;
      _model.text = model;
      _provider = provider;
      _ready = true;
    });
  }

  Future<void> _save() async {
    try {
      await AssistantPrefs.setKind(_kind);
      await AssistantPrefs.setEndpoint(_url.text);
      await AssistantPrefs.setModel(_model.text);
      await AssistantPrefs.setApiProvider(_provider);
      if (_key.text.trim().isNotEmpty) {
        final claude = _kind == AssistantKind.api && _provider == 'claude';
        if (claude) {
          await AiSettings.setApiKey(_key.text.trim());
        } else {
          await AiSettings.setApiKey(
            _key.text.trim(),
            account: AiSettings.openaiAccount,
          );
        }
      }
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Připojit asistenta'),
      content: SizedBox(
        width: 720,
        child: _ready
            ? SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Asistent doplní k přílohám shrnutí, lhůty a termíny. '
                      'Pošta funguje i bez něj: lhůty a štítky pak hlídáte sami.',
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AiSettings.desktop
                          ? 'Najednou je připojený jen jeden. Ten, kterého tu vyberete, nahradí současného.'
                          : 'V telefonu se asistent připojuje přes API klíč. Model v počítači ani Claude Code tu běžet nemohou.',
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in _cards)
                          if (AiSettings.desktop ||
                              AssistantPrefs.mobileKinds.contains(c.kind))
                            _KindCard(
                              card: c,
                              selected: _kind == c.kind,
                              onTap: () => setState(() => _kind = c.kind),
                            ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _fields(text, t),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: text.bodySmall?.copyWith(color: t.danger),
                      ),
                    ],
                  ],
                ),
              )
            : const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _ready ? _save : null, child: const Text('Použít')),
      ],
    );
  }

  static String get _keyStore => Platform.isMacOS
      ? 'Uloží se do Klíčenky tohoto Macu, ne do archivu.'
      : Platform.isIOS
      ? 'Uloží se do Klíčenky tohoto iPhonu, ne do archivu.'
      : 'Uloží se do úložiště hesel tohoto počítače, ne do archivu.';

  Widget _fields(TextTheme text, Tokens t) {
    switch (_kind) {
      case AssistantKind.local:
        return Column(
          children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Adresa modelu',
                hintText: 'http://127.0.0.1:11434/v1',
                helperText: 'Ollama je port 11434, LM Studio obvykle 1234.',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Název modelu',
                hintText: 'llama3.2',
              ),
            ),
          ],
        );
      case AssistantKind.api:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Služba'),
              items: const [
                DropdownMenuItem(value: 'claude', child: Text('Claude')),
                DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
              ],
              onChanged: (v) => setState(() => _provider = v ?? 'claude'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'API klíč',
                helperText: _keyStore,
              ),
            ),
            if (_provider == 'openai') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  hintText: 'gpt-4o-mini',
                ),
              ),
            ],
          ],
        );
      case AssistantKind.subscription:
        return Text(
          'Použije se Claude Code nainstalovaný na tomto počítači, tedy předplatné Claude. '
          'Text příloh může opustit tento počítač.',
          style: text.bodyMedium,
        );
      case AssistantKind.other:
        return TextField(
          controller: _url,
          decoration: const InputDecoration(
            labelText: 'Adresa MCP nebo příkaz',
            hintText: 'http://127.0.0.1:8080/v1  nebo  cursor-agent',
            helperText:
                'Adresa začínající na http se volá jako model. Jinak se příkaz spustí a dostane zadání na vstup.',
          ),
        );
      case AssistantKind.none:
        return Text(
          'Rozbor příloh se nebude nabízet modelu. Lhůty, štítky a hledání dál fungují podle toho, co si nastavíte sami.',
          style: text.bodyMedium,
        );
    }
  }
}

class _KindCard extends StatelessWidget {
  final _Card card;
  final bool selected;
  final VoidCallback onTap;

  const _KindCard({
    required this.card,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    // Grows with longer text (a narrow screen, a larger font) instead of
    // cutting it off.
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 132, maxWidth: 132, minHeight: 118),
      child: Material(
        color: selected ? t.accentSoft : t.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? t.accent : t.line, width: selected ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(card.icon, size: 20, color: selected ? t.accent : t.inkMuted),
                const SizedBox(height: 14),
                Text(
                  card.title,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(card.subtitle, style: text.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
