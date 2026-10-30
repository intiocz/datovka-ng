import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ui/release_notes.dart';
import 'user_error.dart';

/// Version shown to people and compared with GitHub releases.
/// Keep it the same as `version:` in pubspec.yaml (the part before +).
const appVersion = '1.0.5';

/// Tests turn this off so a run never calls GitHub.
bool checkUpdatesOnStart = true;

const _repoKey = 'releaseRepo';
const _channel = MethodChannel('cz.datovka/folder');
const _android = MethodChannel('cz.datovka/android');

/// `vlastník/název` repozitáře, ze kterého se berou balíčky.
/// Stejný strom je na GitHubu a v Gitea. Kontrola vydání jde na GitHub.
class ReleaseSource {
  static const fallback = 'intiocz/datovka-ng';
  static const fromBuild = String.fromEnvironment('DATOVKA_REPO');

  static Future<String> repo() async {
    final saved = (await SharedPreferences.getInstance()).getString(_repoKey);
    if (saved != null && saved.trim().isNotEmpty) return saved.trim();
    if (fromBuild.trim().isNotEmpty) return fromBuild.trim();
    return fallback;
  }

  static Future<void> save(String repo) async {
    final p = await SharedPreferences.getInstance();
    final v = repo.trim();
    if (v.isEmpty) {
      await p.remove(_repoKey);
    } else {
      await p.setString(_repoKey, v);
    }
  }
}

class ReleaseInfo {
  final String version;
  final String notes;
  final String page;
  final String? assetUrl;
  final String? assetName;

  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.page,
    this.assetUrl,
    this.assetName,
  });
}

/// The "what's new" part of release notes as separate points: the text up
/// to the second heading (the install table is for the web page), each
/// bullet or paragraph joined into one line. `**bold**` stays for the view.
List<String> releaseNews(String notes) {
  final points = <String>[];
  var headings = 0;
  String? current;
  void flush() {
    if (current != null && current!.trim().isNotEmpty) points.add(current!.trim());
    current = null;
  }

  for (final raw in notes.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('#')) {
      flush();
      if (++headings > 1 && points.isNotEmpty) break;
      continue;
    }
    if (line.isEmpty || line.startsWith('|')) {
      flush();
      continue;
    }
    final bullet = RegExp(r'^[-*] +').firstMatch(line);
    if (bullet != null) {
      flush();
      current = line.substring(bullet.end);
    } else {
      current = current == null ? line : '$current $line';
    }
  }
  flush();
  return points;
}

/// `true` when [latest] (a tag like `v1.2.0`) is newer than [current].
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) {
    final clean = v.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final main = clean.split('+').first.split('-').first;
    return [for (final p in main.split('.')) int.tryParse(p) ?? 0];
  }

  final a = parts(latest);
  final b = parts(current);
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Link to NENDE.cz that tells the server log where the visit came from
/// (UTM parameters only; the site uses no cookies or trackers for this).
/// [place] is where in the app the link is, e.g. `status-bar` or `help`.
String nendeLink(String place) {
  final platform = Platform.isMacOS
      ? 'macos'
      : Platform.isIOS
      ? 'ios'
      : Platform.isWindows
      ? 'windows'
      : Platform.isAndroid
      ? 'android'
      : Platform.isLinux
      ? (Abi.current() == Abi.linuxArm64 ? 'linux-arm64' : 'linux')
      : 'jine';
  return Uri.https('nende.cz', '/', {
    'utm_source': 'datovka-ng',
    'utm_medium': 'app',
    'utm_campaign': place,
    'utm_content': '$platform-$appVersion',
  }).toString();
}

Future<void> openLink(String url) async {
  if (Platform.isIOS) {
    try {
      await _channel.invokeMethod('open', url);
    } on Object {
      return;
    }
    return;
  }
  final cmd = Platform.isMacOS
      ? ['open', url]
      : Platform.isWindows
      ? ['cmd', '/c', 'start', '', url]
      : ['xdg-open', url];
  await Process.run(cmd.first, cmd.skip(1).toList());
}

/// Soubory přiložené k vydání na GitHubu.
const macReleaseAsset = 'DatovkaNG-macos.zip';
const linuxReleaseAsset = 'DatovkaNG-linux-amd64.deb';
const linuxArmReleaseAsset = 'DatovkaNG-linux-arm64.deb';
const windowsReleaseAsset = 'DatovkaNG-windows-amd64.zip';
const androidReleaseAsset = 'DatovkaNG-android.apk';

/// AppImage for this processor (`x86_64` or `aarch64`).
String appImageAsset(String arch) => 'DatovkaNG-linux-$arch.AppImage';

/// Název balíčku z vydání pro tento systém. Napřed přesný název, pak záloha.
String? releaseAssetName(Iterable<String> names, {required String platform}) {
  final list = names.toList();
  if (platform == 'macos') {
    if (list.contains(macReleaseAsset)) return macReleaseAsset;
    for (final n in list) {
      if (n.endsWith('.zip') && n.toLowerCase().contains('mac')) return n;
    }
  }
  if (platform == 'linux') {
    if (list.contains(linuxReleaseAsset)) return linuxReleaseAsset;
    for (final n in list) {
      if (n.endsWith('.deb') && !n.contains('arm64')) return n;
    }
  }
  // An ARM computer never gets the Intel package.
  if (platform == 'linux-arm64') {
    if (list.contains(linuxArmReleaseAsset)) return linuxArmReleaseAsset;
  }
  // Run from an AppImage, the update is an AppImage of the same processor.
  if (platform.startsWith('appimage-')) {
    final name = appImageAsset(platform.substring('appimage-'.length));
    if (list.contains(name)) return name;
  }
  if (platform == 'android') {
    if (list.contains(androidReleaseAsset)) return androidReleaseAsset;
    for (final n in list) {
      if (n.endsWith('.apk')) return n;
    }
  }
  if (platform == 'windows') {
    if (list.contains(windowsReleaseAsset)) return windowsReleaseAsset;
    for (final n in list) {
      if (n.endsWith('.zip') && n.toLowerCase().contains('win')) return n;
    }
  }
  return null;
}

/// Path of the AppImage this app runs from, null for other installs.
String? get _appImage {
  final p = Platform.environment['APPIMAGE'];
  return p != null && p.isNotEmpty ? p : null;
}

String? _wantedAsset(List assets) {
  final names = [
    for (final a in assets)
      if (a is Map && a['name'] is String) a['name'] as String,
  ];
  final arm = Abi.current() == Abi.linuxArm64;
  final platform = Platform.isMacOS
      ? 'macos'
      : Platform.isLinux && _appImage != null
      ? (arm ? 'appimage-aarch64' : 'appimage-x86_64')
      : Platform.isLinux
      ? (arm ? 'linux-arm64' : 'linux')
      : Platform.isWindows
      ? 'windows'
      : Platform.isAndroid
      ? 'android'
      : '';
  if (platform.isEmpty) return null;
  return releaseAssetName(names, platform: platform);
}

/// Newest GitHub release newer than this build, null when this build is
/// the newest. Throws [UserError] when there is nothing to ask or GitHub
/// cannot be reached, so that is never mistaken for "up to date".
Future<ReleaseInfo?> newerRelease() async {
  removeUpdateLeftovers();
  final repo = await ReleaseSource.repo();
  if (!repo.contains('/')) {
    throw UserError('Aktualizace nejsou zapnuté. Níže uveďte repozitář na GitHubu.');
  }
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
    );
    req.headers.set(HttpHeaders.userAgentHeader, 'DatovkaNG/$appVersion');
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 12));
    if (res.statusCode == 404) {
      throw UserError('V repozitáři $repo zatím není žádné vydání.');
    }
    if (res.statusCode != 200) {
      throw UserError('GitHub odpověděl chybou ${res.statusCode}. Zkuste to později.');
    }
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    if (body is! Map) throw UserError('GitHub poslal nečitelnou odpověď.');
    final tag = '${body['tag_name'] ?? ''}';
    if (!isNewerVersion(tag, appVersion)) return null;
    final assets = body['assets'];
    final list = assets is List ? assets : const [];
    final name = _wantedAsset(list);
    String? url;
    if (name != null) {
      for (final a in list) {
        if (a is Map && a['name'] == name) {
          url = a['browser_download_url'] as String?;
        }
      }
    }
    return ReleaseInfo(
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      notes: '${body['body'] ?? ''}'.trim(),
      page: '${body['html_url'] ?? 'https://github.com/$repo/releases'}',
      assetUrl: url,
      assetName: name,
    );
  } on UserError {
    rethrow;
  } on Object {
    throw UserError('GitHub není dostupný. Zkontrolujte připojení k internetu.');
  } finally {
    client.close(force: true);
  }
}

/// Whether this app can replace itself with [info]; an iPhone cannot.
bool canInstall(ReleaseInfo info) => info.assetUrl != null && !Platform.isIOS;

/// At launch: offers a newer package in a dialog, and says nothing when
/// there is none or GitHub is not reachable.
Future<void> offerUpdate(BuildContext context) async {
  final ReleaseInfo? info;
  try {
    info = await newerRelease();
  } on Object {
    return;
  }
  if (info == null || !context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Nová verze ${info!.version}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: releaseNews(info.notes).isEmpty
              ? const Text('Na GitHubu je novější balíček Datovky NG.')
              : ReleaseNotes(info.notes),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Později'),
        ),
        if (!canInstall(info))
          FilledButton(
            onPressed: () async {
              await openLink(info!.page);
              if (ctx.mounted) Navigator.pop(ctx, false);
            },
            child: const Text('Otevřít vydání'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Aktualizovat'),
          ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Stahuji novou verzi…')));
  try {
    await installRelease(info);
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// Downloads and installs [info]. On a Mac, Windows and from an AppImage the
/// app quits and starts again as the new version; on Android the system asks
/// to confirm the installation. Errors are thrown as [UserError].
Future<void> installRelease(ReleaseInfo info) async {
  final file = File('${Directory.systemTemp.path}/${info.assetName}');
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(info.assetUrl!));
    req.headers.set(HttpHeaders.userAgentHeader, 'DatovkaNG/$appVersion');
    final res = await req.close();
    if (res.statusCode != 200) {
      throw UserError('Stažení skončilo chybou ${res.statusCode}.');
    }
    final sink = file.openWrite();
    await res.pipe(sink);
    if (Platform.isAndroid && file.path.endsWith('.apk')) {
      await _installApk(file);
    } else if (Platform.isLinux &&
        file.path.endsWith('.AppImage') &&
        _appImage != null) {
      await _installAppImage(file, _appImage!);
    } else if (Platform.isMacOS) {
      await _installMac(file);
    } else if (Platform.isWindows &&
        file.path.toLowerCase().endsWith('.zip')) {
      await _installWindows(file);
    } else if (Platform.isLinux && file.path.endsWith('.deb')) {
      await _installDeb(file);
    }
  } on Object {
    if (file.existsSync()) file.deleteSync();
    rethrow;
  } finally {
    client.close(force: true);
  }
}

String _sh(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Replaces this .app after the process exits and deletes the download.
Future<void> _installMac(File zip) async {
  final exe = Platform.resolvedExecutable;
  const mark = '/Contents/MacOS/';
  if (!exe.contains(mark)) {
    throw UserError(
      'Tohle není nainstalovaná aplikace. Balíček zůstává v ${zip.path}.',
    );
  }
  final bundle = exe.split(mark).first;
  final stage = await Directory.systemTemp.createTemp('datovka-ng-');
  final unpack = await Process.run('ditto', ['-x', '-k', zip.path, stage.path]);
  if (unpack.exitCode != 0) {
    throw UserError('Balíček se nepodařilo rozbalit.');
  }
  String? app;
  await for (final e in stage.list(recursive: true)) {
    if (e is Directory && e.path.endsWith('.app')) {
      app = e.path;
      break;
    }
  }
  if (app == null) throw UserError('V balíčku není aplikace.');
  final script = File('${stage.path}/instaluj.sh');
  await script.writeAsString('''
#!/bin/sh
sleep 1
rm -rf ${_sh(bundle)}
ditto ${_sh(app)} ${_sh(bundle)}
rm -rf ${_sh(stage.path)} ${_sh(zip.path)}
open ${_sh(bundle)}
''');
  await Process.start('/bin/sh', [
    script.path,
  ], mode: ProcessStartMode.detached);
  exit(0);
}

/// Replaces the running folder after this process exits and deletes the zip.
Future<void> _installWindows(File zip) async {
  final exe = Platform.resolvedExecutable;
  final dir = File(exe).parent.path;
  final stage = await Directory.systemTemp.createTemp('datovka-ng-');
  final unpack = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    'Expand-Archive -LiteralPath ${_ps(zip.path)} -DestinationPath ${_ps(stage.path)} -Force',
  ]);
  if (unpack.exitCode != 0) {
    throw UserError('Balíček se nepodařilo rozbalit.');
  }
  final script = File(
    '${Directory.systemTemp.path}\\datovka-ng-instaluj.ps1',
  );
  await script.writeAsString('''
Start-Sleep -Seconds 2
Copy-Item -Path ${_ps('${stage.path}\\*')} -Destination ${_ps(dir)} -Recurse -Force
Remove-Item -LiteralPath ${_ps(stage.path)} -Recurse -Force
Remove-Item -LiteralPath ${_ps(zip.path)} -Force -ErrorAction SilentlyContinue
Start-Process -FilePath ${_ps(exe)}
Remove-Item -LiteralPath ${_ps(script.path)} -Force
''');
  await Process.start(
    'powershell',
    windowsInstallerArgs(script.path),
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

/// PowerShell arguments for the install script. Windows refuses to run
/// script files by default, so the policy is lifted for this one run.
List<String> windowsInstallerArgs(String script) => [
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-WindowStyle',
  'Hidden',
  '-File',
  script,
];

String _ps(String s) => "'${s.replaceAll("'", "''")}'";

/// Hands the APK to the Android installer. Android itself refuses a package
/// signed with another key, so only our own build can replace this app.
Future<void> _installApk(File apk) async {
  final r = await _android.invokeMethod<String>('installApk', apk.path);
  switch (r) {
    case 'started':
      return;
    case 'permission':
      throw UserError(
        'Android potřebuje svolení, aby Datovka NG mohla instalovat '
        'aplikace. V otevřeném nastavení ho zapněte a pak klikněte na '
        'Aktualizovat znovu.',
      );
    case 'foreign':
      if (apk.existsSync()) apk.deleteSync();
      throw UserError('Stažený balíček není Datovka NG, instalace se zrušila.');
    default:
      throw UserError('Instalaci se nepodařilo spustit.');
  }
}

/// Puts the new AppImage in place of the running one and starts it.
Future<void> _installAppImage(File download, String target) async {
  // Next to the old file, so the rename stays on one disk and is atomic.
  final next = File('$target.nova');
  try {
    await download.copy(next.path);
    await download.delete();
    final chmod = await Process.run('chmod', ['+x', next.path]);
    if (chmod.exitCode != 0) {
      throw UserError('Nová verze nejde nastavit jako spustitelná.');
    }
    await next.rename(target);
  } on FileSystemException {
    if (next.existsSync()) next.deleteSync();
    throw UserError(
      'Soubor $target nejde přepsat. Stáhněte novou verzi ručně, '
      'nebo AppImage přesuňte do své složky.',
    );
  }
  await Process.start(target, const [], mode: ProcessStartMode.detached);
  exit(0);
}

/// Removes an APK left over from an update; Android installs it while this
/// app is closed, so it cannot clean up right after.
void removeUpdateLeftovers() {
  if (!Platform.isAndroid) return;
  try {
    final f = File('${Directory.systemTemp.path}/$androidReleaseAsset');
    if (f.existsSync()) f.deleteSync();
  } on Object {
    // Only tidying up.
  }
}

Future<void> _installDeb(File deb) async {
  final r = await Process.run('pkexec', ['dpkg', '-i', deb.path]);
  if (r.exitCode != 0) {
    throw UserError(
      'Instalace se nepovedla: ${(r.stderr as String).trim()}',
    );
  }
  if (deb.existsSync()) deb.deleteSync();
}
