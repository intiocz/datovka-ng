import 'dart:io';

import 'package:datovka/data/auto_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backups are named by time and sort by name', () {
    expect(
      autoBackupName(DateTime(2026, 3, 7, 9, 5)),
      'Datovka-zaloha-2026-03-07-0905.zip',
    );
  });

  test('a backup is due after the chosen number of days', () {
    final last = DateTime(2026, 10, 30, 8);
    expect(autoBackupDue(null, 1, last), isTrue);
    expect(autoBackupDue(last, 1, DateTime(2026, 10, 31, 7)), isFalse);
    expect(autoBackupDue(last, 1, DateTime(2026, 10, 31, 8)), isTrue);
    expect(autoBackupDue(last, 7, DateTime(2026, 11, 5)), isFalse);
  });

  test('only our oldest backups beyond the kept ones are removed', () {
    final dir = Directory.systemTemp.createTempSync('datovka-zalohy-');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final d in [1, 2, 3, 4, 5]) {
      File('${dir.path}/${autoBackupName(DateTime(2026, 10, d, 12))}')
          .writeAsStringSync('x');
    }
    File('${dir.path}/moje-faktura.zip').writeAsStringSync('cizí');
    File('${dir.path}/Datovka-zaloha-rucni.zip').writeAsStringSync('cizí');
    final gone = surplusBackups(dir, 3).map((f) => f.uri.pathSegments.last);
    expect(gone, [
      'Datovka-zaloha-2026-10-02-1200.zip',
      'Datovka-zaloha-2026-10-01-1200.zip',
    ]);
    expect(surplusBackups(Directory('${dir.path}/neni'), 3), isEmpty);
  });
}
