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
  });

  test('a newer tag is newer, the same tag is not', () {
    expect(isNewerVersion('v1.2.0', '1.0.0'), isTrue);
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('v1.0.0', '1.0.1'), isFalse);
    expect(isNewerVersion('v2', '1.9.9'), isTrue);
  });
}
