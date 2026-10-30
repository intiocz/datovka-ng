import 'dart:io';

/// Automatic backups: ZIP files named by their time in a folder the user
/// picks, the newest few kept.
const _prefix = 'Datovka-zaloha-';

/// File name of an automatic backup made at [t] (local time, sorts by name).
String autoBackupName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '$_prefix${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}${two(t.minute)}.zip';
}

/// Whether the next backup is due [days] after [last].
bool autoBackupDue(DateTime? last, int days, DateTime now) =>
    last == null || !now.isBefore(last.add(Duration(days: days)));

/// Automatic backups in [dir] beyond the newest [keep], to be deleted.
/// Other files in the folder are never touched.
List<File> surplusBackups(Directory dir, int keep) {
  if (!dir.existsSync()) return const [];
  final ours = [
    for (final f in dir.listSync().whereType<File>())
      if (_ours(f.uri.pathSegments.last)) f,
  ]..sort((a, b) => b.path.compareTo(a.path));
  return ours.skip(keep.clamp(1, 1000)).toList();
}

bool _ours(String name) =>
    RegExp(r'^Datovka-zaloha-\d{4}-\d{2}-\d{2}-\d{4}\.zip$').hasMatch(name);
