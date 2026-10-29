import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'user_error.dart';

/// How the assistant is connected. One at a time; mail works without one.
enum AssistantKind { local, api, subscription, other, none }

/// How the AI assistant reaches Claude when the kind is the API or a subscription.
enum AiMode { cli, api }

/// One date found in the documents.
class AiEvent {
  final String title;
  final DateTime date;
  final String time;
  final String endTime;
  final String kind;
  final String location;
  final String description;
  final String source;

  AiEvent.fromJson(Map<String, dynamic> j)
    : title = j['title'] as String? ?? '',
      date = DateTime.parse(j['date'] as String),
      time = j['time'] as String? ?? '',
      endTime = j['end_time'] as String? ?? '',
      kind = j['kind'] as String? ?? 'jine',
      location = j['location'] as String? ?? '',
      description = j['description'] as String? ?? '',
      source = j['source'] as String? ?? '';
}

class AiResult {
  final String summary;
  final DateTime? suggestedDeadline;
  final List<AiEvent> events;

  AiResult.fromJson(Map<String, dynamic> j)
    : summary = j['summary'] as String? ?? '',
      suggestedDeadline = DateTime.tryParse(
        j['suggested_deadline'] as String? ?? '',
      ),
      events = [
        for (final e in (j['events'] as List? ?? const []))
          if (DateTime.tryParse((e as Map)['date'] as String? ?? '') != null)
            AiEvent.fromJson(e.cast<String, dynamic>()),
      ];
}

/// The date that stays on the message: the model's suggestion, otherwise the
/// earliest deadline or payment. Meetings do not start the progress bar.
DateTime? rememberedDeadline(AiResult r) {
  if (r.suggestedDeadline != null) return r.suggestedDeadline;
  final dates = [
    for (final e in r.events)
      if (e.kind == 'lhuta' || e.kind == 'platba') e.date,
  ]..sort();
  return dates.isEmpty ? null : dates.first;
}

/// The API key is kept in the Keychain or the system's password store (never
/// in the synced folder); `ANTHROPIC_API_KEY` from the environment works as
/// well.
class AiSettings {
  static const _service = 'cz.nende.datovka-ng';
  static const _previousService = 'cz.user.datovka';
  static const _account = 'anthropic-api-key';
  static const openaiAccount = 'openai-api-key';

  static Future<String?> apiKey({String account = _account}) async {
    if (account == _account) {
      final env = Platform.environment['ANTHROPIC_API_KEY'];
      if (env != null && env.isNotEmpty) return env;
    }
    if (account == openaiAccount) {
      final env = Platform.environment['OPENAI_API_KEY'];
      if (env != null && env.isNotEmpty) return env;
    }
    if (!Platform.isMacOS) return _stored(account);
    final r = await Process.run('security', [
      'find-generic-password',
      '-s',
      _service,
      '-a',
      account,
      '-w',
    ]);
    final key = (r.stdout as String).trim();
    if (r.exitCode == 0 && key.isNotEmpty) return key;
    if (account != _account) return null;
    final old = await Process.run('security', [
      'find-generic-password',
      '-s',
      _previousService,
      '-a',
      account,
      '-w',
    ]);
    final previous = (old.stdout as String).trim();
    return old.exitCode == 0 && previous.isNotEmpty ? previous : null;
  }

  static Future<void> setApiKey(String key, {String account = _account}) async {
    if (!Platform.isMacOS) return _store(account, key);
    final r = await Process.run('security', [
      'add-generic-password',
      '-U',
      '-s',
      _service,
      '-a',
      account,
      '-w',
      key,
    ]);
    if (r.exitCode != 0) {
      throw UserError('Klíč se nepodařilo uložit do Klíčenky.');
    }
  }

  static Future<void> deleteApiKey({String account = _account}) async {
    if (!Platform.isMacOS) return _store(account, '');
    await Process.run('security', [
      'delete-generic-password',
      '-s',
      _service,
      '-a',
      account,
    ]);
  }

  static bool get desktop => !Platform.isIOS && !Platform.isAndroid;

  /// Elsewhere than on a Mac the key goes to the system store through the
  /// core: Keychain on iPhone, Credential Manager, Secret Service.
  static String? _stored(String account) {
    try {
      final v = CoreBridge.open()?.call('secret_get', [account]);
      return v is String && v.isNotEmpty ? v : null;
    } on Object {
      return null;
    }
  }

  static void _store(String account, String key) {
    final core = CoreBridge.open();
    if (core == null) {
      throw UserError('Klíč tu nejde uložit.');
    }
    try {
      core.call('secret_set', [account, key]);
    } on Object {
      throw UserError('Klíč se nepodařilo uložit do úložiště hesel.');
    }
  }

  /// Path of the Claude Code CLI; GUI apps do not get the shell PATH, so it is
  /// looked up through a login shell and well-known locations.
  static Future<String?> claudeCli() async {
    // A phone runs no other programs.
    if (!desktop) return null;
    final home = Platform.environment['HOME'] ?? '';
    for (final p in [
      '$home/.claude/local/claude',
      '$home/.local/bin/claude',
      '/opt/homebrew/bin/claude',
      '/usr/local/bin/claude',
    ]) {
      if (File(p).existsSync()) return p;
    }
    if (Platform.isWindows) return null;
    // The login shell knows the user's PATH. Not every system has zsh
    // (Linux usually has bash), so ask the user's own shell, or sh.
    final shell = Platform.environment['SHELL'];
    try {
      final r = await Process.run(
        shell != null && File(shell).existsSync() ? shell : '/bin/sh',
        ['-lc', 'command -v claude'],
      );
      final p = (r.stdout as String).trim();
      return r.exitCode == 0 && p.isNotEmpty ? p : null;
    } on ProcessException {
      return null;
    }
  }

  /// Local Claude Code when it is installed, otherwise the API.
  static Future<AiMode?> mode() async {
    if (await claudeCli() != null) return AiMode.cli;
    if (await apiKey() != null) return AiMode.api;
    return null;
  }
}

/// Runs the analysis of a message's attachments. Only called on user request.
Future<AiResult> analyzeMessage(CoreBridge? core, Message m) async {
  final kind = await AssistantPrefs.kind();
  if (kind == AssistantKind.none) {
    throw UserError(
      'Asistent je vypnutý. Lhůty a štítky si nastavíte u zprávy ručně.',
    );
  }
  if (core == null) {
    throw UserError('Asistent tu není k dispozici.');
  }
  if (kind == AssistantKind.api) {
    final provider = await AssistantPrefs.apiProvider();
    if (provider == 'openai') {
      final key = await AiSettings.apiKey(account: AiSettings.openaiAccount);
      if (key == null) throw UserError('Chybí API klíč OpenAI.');
      return _askTextModel(
        core,
        m,
        url: 'https://api.openai.com/v1',
        model: await AssistantPrefs.model(fallback: 'gpt-4o-mini'),
        key: key,
      );
    }
    final key = await AiSettings.apiKey();
    if (key == null) throw UserError('Chybí API klíč Claude.');
    final r = await core.callAsync('ai_analyze', [
      '',
      m.boxId,
      int.parse(m.dmId),
      key,
    ]);
    return AiResult.fromJson((r as Map).cast<String, dynamic>());
  }
  if (kind == AssistantKind.local || kind == AssistantKind.other) {
    final url = await AssistantPrefs.endpoint();
    if (url.startsWith('http')) {
      return _askTextModel(
        core,
        m,
        url: url,
        model: await AssistantPrefs.model(
          fallback: kind == AssistantKind.local ? 'llama3.2' : 'local',
        ),
        key: await AiSettings.apiKey(account: AiSettings.openaiAccount) ?? '',
      );
    }
    if (kind == AssistantKind.other) {
      final cmd = url.trim();
      if (cmd.isEmpty) {
        throw UserError(
          'Vyplňte adresu MCP nebo příkaz aplikace, která má přílohy přečíst.',
        );
      }
      return _askCommand(core, m, cmd);
    }
  }
  final cli = await AiSettings.claudeCli();
  if (cli == null) {
    throw UserError(
      'Předplatné tu není dostupné. Nainstalujte Claude Code, nebo zvolte API klíč.',
    );
  }
  final dir = Directory('${Directory.systemTemp.path}/datovka-ai/${m.dmId}')
    ..createSync(recursive: true);
  try {
    final p = core.call('ai_cli_prompt', [
      '',
      m.boxId,
      int.parse(m.dmId),
      dir.path,
    ]) as Map;
    final r = await Process.run(cli, [
      '-p',
      p['prompt'] as String,
      '--output-format',
      'text',
      '--allowedTools',
      'Read',
      '--add-dir',
      dir.path,
    ], workingDirectory: dir.path);
    if (r.exitCode != 0) {
      throw UserError(
        'Claude Code skončil chybou: ${(r.stderr as String).trim()}',
      );
    }
    final j = core.call('ai_parse_text', [r.stdout as String]) as Map;
    return AiResult.fromJson(j.cast<String, dynamic>());
  } finally {
    dir.deleteSync(recursive: true);
  }
}

String _esc(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\n', '\\n');

String _d(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

bool _due(AiEvent e) => e.kind == 'lhuta' || e.kind == 'platba';

DateTime _calendarDay(AiEvent e) =>
    _due(e) ? e.date.subtract(const Duration(days: 1)) : e.date;

String _notes(Message m, AiEvent e) => [
  if (_due(e))
    'Skutečná lhůta je ${e.date.day}. ${e.date.month}. ${e.date.year}, v kalendáři je o den dřív.',
  e.description,
  if (e.source.isNotEmpty) '„${e.source}“',
  'Datová zpráva ${m.dmId}: ${m.subject} (${m.counterparty})',
].where((x) => x.isNotEmpty).join('\n\n');

/// The same events as [buildIcs] for the phone's calendar, which takes them
/// directly: start and end in milliseconds of local time.
List<Map<String, Object>> calendarEntries(Message m, List<AiEvent> events) {
  DateTime at(DateTime day, String hm) {
    final p = hm.split(':');
    return DateTime(day.year, day.month, day.day, int.parse(p[0]), int.parse(p[1]));
  }

  return [
    for (final e in events)
      () {
        final day = _calendarDay(e);
        final allDay = e.time.isEmpty;
        final start = allDay ? DateTime(day.year, day.month, day.day) : at(day, e.time);
        final end = allDay
            ? start.add(const Duration(days: 1))
            : e.endTime.isEmpty || e.endTime == e.time
            ? start.add(const Duration(hours: 1))
            : at(day, e.endTime);
        return <String, Object>{
          'title': e.title,
          'start': start.millisecondsSinceEpoch,
          'end': end.millisecondsSinceEpoch,
          'allDay': allDay,
          'location': e.location,
          'notes': _notes(m, e),
          'alarm': _due(e),
        };
      }(),
  ];
}

/// iCalendar file with the selected events. Deadlines and payments go in a
/// day early so there is time to act; the real date stays in the description.
/// They also get a reminder a day ahead of that.
String buildIcs(Message m, List<AiEvent> events) {
  final now = DateTime.now().toUtc();
  final stamp =
      '${_d(now)}T${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}00Z';
  final out = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//DATOVKA//CS',
    'CALSCALE:GREGORIAN',
  ];
  for (final (i, e) in events.indexed) {
    final due = _due(e);
    final date = _calendarDay(e);
    final allDay = e.time.isEmpty;
    final hm = e.time.replaceAll(':', '');
    final endHm = (e.endTime.isEmpty ? e.time : e.endTime).replaceAll(':', '');
    out.addAll([
      'BEGIN:VEVENT',
      'UID:datovka-${m.dmId}-$i@datovka',
      'DTSTAMP:$stamp',
      if (allDay)
        'DTSTART;VALUE=DATE:${_d(date)}'
      else
        'DTSTART:${_d(date)}T${hm}00',
      if (allDay)
        'DTEND;VALUE=DATE:${_d(date.add(const Duration(days: 1)))}'
      else
        'DTEND:${_d(date)}T${endHm == hm ? '${(int.parse(hm.substring(0, 2)) + 1).clamp(0, 23).toString().padLeft(2, '0')}${hm.substring(2)}' : endHm}00',
      'SUMMARY:${_esc(e.title)}',
      if (e.location.isNotEmpty) 'LOCATION:${_esc(e.location)}',
      'DESCRIPTION:${_esc(_notes(m, e))}',
      if (due) ...[
        'BEGIN:VALARM',
        'ACTION:DISPLAY',
        'DESCRIPTION:${_esc(e.title)}',
        'TRIGGER:-P1D',
        'END:VALARM',
      ],
      'END:VEVENT',
    ]);
  }
  out.add('END:VCALENDAR');
  return '${out.join('\r\n')}\r\n';
}

/// Which assistant is connected, and the few fields it needs.
class AssistantPrefs {
  /// A phone can only call a model over the internet.
  static const mobileKinds = [AssistantKind.api, AssistantKind.none];

  static const _kind = 'assistantKind';
  static const _url = 'assistantUrl';
  static const _model = 'assistantModel';
  static const _provider = 'assistantApiProvider';

  static Future<AssistantKind> kind() async {
    final v = (await SharedPreferences.getInstance()).getString(_kind);
    final known = AssistantKind.values.where((k) => k.name == v).firstOrNull;
    if (known != null && (AiSettings.desktop || mobileKinds.contains(known))) {
      return known;
    }
    if (await AiSettings.claudeCli() != null) return AssistantKind.subscription;
    if (await AiSettings.apiKey() != null) return AssistantKind.api;
    return AssistantKind.none;
  }

  static Future<void> setKind(AssistantKind k) async {
    await (await SharedPreferences.getInstance()).setString(_kind, k.name);
  }

  static Future<String> endpoint() async {
    final v = (await SharedPreferences.getInstance()).getString(_url) ?? '';
    if (v.trim().isNotEmpty) return v.trim();
    final k = await kind();
    if (k == AssistantKind.local) return 'http://127.0.0.1:11434/v1';
    return '';
  }

  static Future<void> setEndpoint(String v) async {
    await (await SharedPreferences.getInstance()).setString(_url, v.trim());
  }

  static Future<String> model({required String fallback}) async {
    final v = (await SharedPreferences.getInstance()).getString(_model) ?? '';
    return v.trim().isEmpty ? fallback : v.trim();
  }

  static Future<void> setModel(String v) async {
    await (await SharedPreferences.getInstance()).setString(_model, v.trim());
  }

  static Future<String> apiProvider() async {
    return (await SharedPreferences.getInstance()).getString(_provider) ??
        'claude';
  }

  static Future<void> setApiProvider(String v) async {
    await (await SharedPreferences.getInstance()).setString(_provider, v);
  }
}

/// What the consent screen must say before a reading starts.
class AssistantNotice {
  final String text;
  final String button;

  const AssistantNotice(this.text, this.button);
}

/// Shown before a reading starts. Null when the assistant is off.
Future<AssistantNotice?> assistantNotice() async {
  if (await AssistantPrefs.kind() == AssistantKind.none) return null;
  return AssistantNotice(
    'Text příloh může opustit ${AiSettings.desktop ? 'tento počítač' : 'toto zařízení'}.',
    'Odeslat k rozboru',
  );
}

Future<String> _prompt(CoreBridge core, Message m) async {
  final dir = Directory('${Directory.systemTemp.path}/datovka-ai/${m.dmId}')
    ..createSync(recursive: true);
  final p = core.call('ai_cli_prompt', [
    '',
    m.boxId,
    int.parse(m.dmId),
    dir.path,
  ]) as Map;
  final buf = StringBuffer(p['prompt'] as String);
  final files = (p['files'] as List?) ?? const [];
  for (final path in files) {
    final f = File('$path');
    if (!f.existsSync()) continue;
    final name = f.uri.pathSegments.last.toLowerCase();
    final texty =
        name.endsWith('.txt') ||
        name.endsWith('.xml') ||
        name.endsWith('.html') ||
        name.endsWith('.csv');
    if (!texty || f.lengthSync() > 200000) continue;
    buf.writeln('\n\n--- ${f.uri.pathSegments.last} ---\n');
    buf.write(await f.readAsString());
  }
  return buf.toString();
}

Future<AiResult> _askTextModel(
  CoreBridge core,
  Message m, {
  required String url,
  required String model,
  required String key,
}) async {
  final prompt = await _prompt(core, m);
  final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$base/chat/completions'));
    req.headers.contentType = ContentType.json;
    if (key.isNotEmpty) req.headers.set('authorization', 'Bearer $key');
    req.add(
      utf8.encode(
        jsonEncode({
          'model': model,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        }),
      ),
    );
    final res = await req.close().timeout(const Duration(minutes: 3));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw UserError('Model odpověděl chybou ${res.statusCode}.');
    }
    final decoded = jsonDecode(text);
    final content =
        decoded['choices']?[0]?['message']?['content'] as String? ?? '';
    final parsed = core.call('ai_parse_text', [content]) as Map;
    return AiResult.fromJson(parsed.cast<String, dynamic>());
  } finally {
    client.close(force: true);
  }
}

Future<AiResult> _askCommand(CoreBridge core, Message m, String cmd) async {
  final prompt = await _prompt(core, m);
  final p = await Process.start('/bin/sh', ['-c', cmd]);
  p.stdin.write(prompt);
  await p.stdin.close();
  final out = await p.stdout.transform(utf8.decoder).join();
  final err = await p.stderr.transform(utf8.decoder).join();
  if (await p.exitCode != 0) {
    throw UserError('Aplikace skončila chybou: ${err.trim()}');
  }
  final parsed = core.call('ai_parse_text', [out]) as Map;
  return AiResult.fromJson(parsed.cast<String, dynamic>());
}
