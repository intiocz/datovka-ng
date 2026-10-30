/// Result of checking the files of a message against the ISDS rules
/// (`rules::check_files` in the core).
class FileCheck {
  final List<FileProblem> problems;
  final int totalBytes;

  /// Goes as a high-volume message (VoDZ).
  final bool big;

  const FileCheck({
    this.problems = const [],
    this.totalBytes = 0,
    this.big = false,
  });

  factory FileCheck.fromJson(Map<String, dynamic> j) => FileCheck(
    problems: [
      for (final p in (j['problems'] as List? ?? const []))
        FileProblem(
          error: p['severity'] == 'error',
          file: p['file'] as String?,
          text: '${p['text']}',
        ),
    ],
    totalBytes: (j['total_bytes'] as num?)?.toInt() ?? 0,
    big: j['big'] == true,
  );

  /// ISDS would refuse the message.
  bool get blocks => problems.any((p) => p.error);
}

class FileProblem {
  /// Blocks sending; otherwise a warning.
  final bool error;
  final String? file;
  final String text;

  const FileProblem({required this.error, this.file, required this.text});
}
