import 'package:datovka/data/updates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('picks the GitHub release package by its published name', () {
    const names = [
      'DatovkaNG-macos.zip',
      'DatovkaNG-linux-amd64.deb',
      'DatovkaNG-windows-amd64.zip',
      'poznamky.txt',
    ];
    expect(releaseAssetName(names, platform: 'macos'), 'DatovkaNG-macos.zip');
    expect(
      releaseAssetName(names, platform: 'linux'),
      'DatovkaNG-linux-amd64.deb',
    );
    expect(
      releaseAssetName(names, platform: 'windows'),
      'DatovkaNG-windows-amd64.zip',
    );
    expect(releaseAssetName(names, platform: 'ios'), isNull);
    final both = [...names, 'DatovkaNG-linux-arm64.deb'];
    expect(
      releaseAssetName(both, platform: 'linux-arm64'),
      'DatovkaNG-linux-arm64.deb',
    );
    expect(releaseAssetName(both, platform: 'linux'), 'DatovkaNG-linux-amd64.deb');
    expect(releaseAssetName(names, platform: 'linux-arm64'), isNull);
  });

  test('a newer tag is newer, the same tag is not', () {
    expect(isNewerVersion('v1.2.0', '1.0.0'), isTrue);
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('v1.0.0', '1.0.1'), isFalse);
    expect(isNewerVersion('v2', '1.9.9'), isTrue);
  });

  test('the app shows only what is new, not the install table', () {
    const notes = '''## Co je nového

- **Telefon**: schránky jsou podle abecedy
  a nedají se přetahovat.
- **Verze ve stavovém řádku** dole.

## Instalace

Ručně ji stáhnete z tabulky níže.

| Systém | Soubor |
|---|---|
| macOS | `DatovkaNG-macos.zip` |
''';
    expect(releaseNews(notes), [
      '**Telefon**: schránky jsou podle abecedy a nedají se přetahovat.',
      '**Verze ve stavovém řádku** dole.',
    ]);
    expect(releaseNews('Opravy chyb.'), ['Opravy chyb.']);
    expect(releaseNews(''), isEmpty);
  });

  test('the Windows install script runs despite the default script policy', () {
    final args = windowsInstallerArgs(r'C:\Temp\datovka-ng-instaluj.ps1');
    final i = args.indexOf('-ExecutionPolicy');
    expect(i, isNot(-1));
    expect(args[i + 1], 'Bypass');
    expect(args.indexOf('-File'), lessThan(args.length - 1));
    expect(args.last, r'C:\Temp\datovka-ng-instaluj.ps1');
    expect(i, lessThan(args.indexOf('-File')));
  });
}
