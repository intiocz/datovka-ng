import 'dart:io';

import 'data_folder.dart';
import 'user_error.dart';

/// Where the archive lives.
///
/// On a Mac and on an iPhone it is one package, `Archiv.datovka`. Finder and
/// Files show it as a single item. Inside are the same files the original
/// Datovka uses, and the write lock that lets several launches read at once.
/// When iCloud Drive is on, the package sits in its Documents folder, so it
/// syncs with the other Apple devices. Linux and Windows keep `~/.dsgui`.
class ArchiveLocation {
  static const packageName = 'Archiv.datovka';

  /// Resolved folder the core should open. Null only when an iPhone has
  /// neither a saved folder nor its own Documents directory.
  static Future<String?> resolve({String? saved, String? restored}) async {
    if (restored != null && restored.isNotEmpty) return restored;
    if (saved != null &&
        saved.isNotEmpty &&
        Directory(saved).existsSync() &&
        !(Platform.isIOS && await _emptyOnPhone(saved))) {
      return saved;
    }
    if (Platform.isMacOS) return _mac();
    // On a phone the archive normally comes from iCloud Drive: ask for it,
    // unless the user already started one in the phone itself.
    if (Platform.isIOS) {
      final docs = await DataFolder.documents();
      final local = docs == null ? null : '$docs/$packageName';
      if (local != null && File('$local/dsgui.conf').existsSync()) return local;
      return null;
    }
    return null;
  }

  /// The phone folder earlier builds created on their own, never filled.
  static Future<bool> _emptyOnPhone(String dir) async {
    final docs = await DataFolder.documents();
    return docs != null &&
        dir == '$docs/$packageName' &&
        !File('$dir/dsgui.conf').existsSync();
  }

  /// A new archive in the phone's own storage, for someone without one in
  /// iCloud Drive.
  static Future<String?> newOnPhone() => _iosDocuments();

  static Future<String> _mac() async {
    final pkg = macPackagePath();
    final legacy = legacyDir();
    final hasNew = File('$pkg/dsgui.conf').existsSync();
    final hasOld = legacy != null && File('$legacy/dsgui.conf').existsSync();
    // Do not duplicate a large existing archive on first launch.
    if (!hasNew && hasOld) return legacy;
    await Directory(pkg).create(recursive: true);
    return pkg;
  }

  static Future<String?> _iosDocuments() async {
    final docs = await DataFolder.documents();
    if (docs == null || docs.isEmpty) return null;
    final pkg = '$docs/$packageName';
    await Directory(pkg).create(recursive: true);
    return pkg;
  }

  static String? legacyDir() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/.dsgui';
  }

  /// `Archiv.datovka` in iCloud Drive Documents when that drive exists,
  /// otherwise in the local Documents folder.
  static String macPackagePath() {
    final home = Platform.environment['HOME'] ?? '';
    final cloud = '$home/Library/Mobile Documents/com~apple~CloudDocs';
    final root = Directory(cloud).existsSync()
        ? '$cloud/Documents/Datovka NG'
        : '$home/Documents/Datovka NG';
    return '$root/$packageName';
  }

  static bool isLegacy(String? dir) {
    if (dir == null) return false;
    return dir.endsWith('/.dsgui') || dir.endsWith('.dsgui');
  }

  /// Where the folder really is: `~/.dsgui` is often a link into iCloud Drive.
  static String resolved(String dir) {
    try {
      return Directory(dir).resolveSymbolicLinksSync();
    } on Object {
      return dir;
    }
  }

  static bool _inCloud(String dir) =>
      dir.contains('Mobile Documents') || dir.contains('iCloud');

  /// The archive of the original app that only this computer sees, so it is
  /// worth copying into iCloud Drive.
  static bool isLocalLegacy(String? dir) =>
      isLegacy(dir) && !_inCloud(resolved(dir!));

  static String storageLabel(String? dir) {
    if (dir == null || dir.isEmpty) return 'žádný archiv';
    if (_inCloud(dir) || (isLegacy(dir) && _inCloud(resolved(dir)))) {
      return 'iCloud Drive';
    }
    if (isLegacy(dir)) return 'původní Datovka';
    if (dir.contains('/Documents/')) return 'Dokumenty';
    return 'složka archivu';
  }

  /// Copies `~/.dsgui` into the Documents package and returns the new path.
  static Future<String> copyLegacyIntoDocuments() async {
    final from = legacyDir();
    if (from == null || !Directory(from).existsSync()) {
      throw UserError('Původní složka ~/.dsgui tu není.');
    }
    final to = macPackagePath();
    await Directory(to).create(recursive: true);
    final r = await Process.run('rsync', [
      '-a',
      '--exclude',
      '.datovka-zamek.json',
      '$from/',
      '$to/',
    ]);
    if (r.exitCode != 0) {
      throw UserError(
        'Archiv se nepodařilo zkopírovat: ${(r.stderr as String).trim()}',
      );
    }
    return to;
  }
}
