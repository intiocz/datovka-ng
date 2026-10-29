import 'dart:io';

import 'package:flutter/services.dart';

/// What only the Android side of the app can do: the Keystore key for the
/// passwords file, and handing files to other apps.
class AndroidBridge {
  static const _channel = MethodChannel('cz.datovka/android');

  /// 32 random bytes kept wrapped by the Android Keystore, as hex.
  static Future<String?> secretKey() async {
    if (!Platform.isAndroid) return null;
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('secretKey');
      if (bytes == null || bytes.length != 32) return null;
      return [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
    } on Object {
      return null;
    }
  }

  /// Opens [path] in another app; false when no app can open it.
  static Future<bool> open(String path) async =>
      await _channel.invokeMethod<bool>('open', path) ?? false;

  /// Offers [path] to other apps (Drive, e-mail, Files).
  static Future<bool> share(String path) async =>
      await _channel.invokeMethod<bool>('share', path) ?? false;
}
