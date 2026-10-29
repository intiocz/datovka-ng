String _two(int n) => n.toString().padLeft(2, '0');

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Compact date for lists: time today, "včera", day.month. this year, full otherwise.
String shortDate(DateTime d, {DateTime? now}) {
  now ??= DateTime.now();
  final days = _day(now).difference(_day(d)).inDays;
  if (days == 0) return '${d.hour}:${_two(d.minute)}';
  if (days == 1) return 'včera';
  if (d.year == now.year) return '${d.day}. ${d.month}.';
  return '${d.day}. ${d.month}. ${d.year}';
}

String longDate(DateTime d) =>
    '${d.day}. ${d.month}. ${d.year} ${d.hour}:${_two(d.minute)}';

String dayDate(DateTime d) => '${d.day}. ${d.month}. ${d.year}';

/// Czech plural for days: 1 den, 2–4 dny, 5+ dní.
String days(int n) {
  final a = n.abs();
  if (a == 1) return '$a den';
  if (a >= 2 && a <= 4) return '$a dny';
  return '$a dní';
}

/// Whole days from today to [d] (negative when in the past).
int daysUntil(DateTime d, {DateTime? now}) =>
    _day(d).difference(_day(now ?? DateTime.now())).inDays;

String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} kB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
}

String relativeAgo(DateTime d) {
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 1) return 'právě teď';
  if (m < 60) return 'před $m min';
  final h = m ~/ 60;
  if (h < 24) return 'před $h h';
  return 'dne ${dayDate(d)}';
}

const monthNames = [
  'leden',
  'únor',
  'březen',
  'duben',
  'květen',
  'červen',
  'červenec',
  'srpen',
  'září',
  'říjen',
  'listopad',
  'prosinec',
];

/// "2025" or "březen 2025".
String periodLabel(({int year, int? month}) p) =>
    p.month == null ? '${p.year}' : '${monthNames[p.month! - 1]} ${p.year}';
