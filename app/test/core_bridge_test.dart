// The native core is optional here. This file must never open the home
// archive (~/.dsgui) and must never print subjects, names or paths from it.
import 'dart:io';

import 'package:datovka/data/core_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fixture = String.fromEnvironment('DATOVKA_FIXTURE');

  test('a fixture path is not the home archive', () {
    final home = Platform.environment['HOME'];
    expect(fixture.contains('/.dsgui'), isFalse);
    if (home != null && home.isNotEmpty) {
      expect(fixture.startsWith(home), isFalse);
    }
  });

  test('account list from a fixture contains no secrets', () async {
    final core = CoreBridge.open();
    expect(fixture, isNotEmpty, reason: 'bez DATOVKA_FIXTURE se test nespouští');
    final raw = core!.call('accounts', [fixture]).toString();
    for (final secret in ['password', 'mep_token', 'pwd_code', 'secret']) {
      expect(raw.contains(secret), isFalse);
    }
  }, skip: fixture.isEmpty ? 'no throwaway fixture' : false);
}
