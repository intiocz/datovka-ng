import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'android_bridge.dart';
import 'data_folder.dart';
import 'user_error.dart';

typedef _Str = Pointer<Utf8>;

/// Thin wrapper over `libdatovka_ffi` (see `ffi/src/lib.rs`).
class CoreBridge {
  final DynamicLibrary _lib;
  late final void Function(_Str) _free = _lib
      .lookupFunction<Void Function(_Str), void Function(_Str)>('dk_free');

  CoreBridge._(this._lib);

  /// Path of the library during development, set with
  /// `--dart-define=DATOVKA_FFI=/abs/path/libdatovka_ffi.dylib`.
  static const _devPath = String.fromEnvironment('DATOVKA_FFI');

  /// Data folder passed to the core; empty means `~/.dsgui` (desktop).
  /// On iOS/Android the user picks the synced folder.
  static String dataDir = '';

  static CoreBridge? open() {
    // iOS links the core statically into the app.
    if (Platform.isIOS) {
      final lib = DynamicLibrary.process();
      return lib.providesSymbol('dk_free') ? CoreBridge._(lib) : null;
    }
    final name = Platform.isWindows
        ? 'datovka_ffi.dll'
        : Platform.isMacOS || Platform.isIOS
        ? 'libdatovka_ffi.dylib'
        : 'libdatovka_ffi.so';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      if (_devPath.isNotEmpty) _devPath,
      '$exeDir/../Frameworks/$name',
      '$exeDir/lib/$name',
      '$exeDir/$name',
      name,
    ];
    for (final c in candidates) {
      try {
        return CoreBridge._(DynamicLibrary.open(c));
      } on ArgumentError {
        continue;
      }
    }
    return null;
  }

  /// Calls `dk_<fn>` with string and integer/bool arguments; returns the `ok`
  /// value or throws [CoreError].
  dynamic call(String fn, List<Object> args) {
    args = argsWithDataDir(fn, args, dataDir);
    final arena = Arena();
    try {
      final native = <Object>[
        for (final a in args)
          if (a is String) a.toNativeUtf8(allocator: arena) else a,
      ];
      final result = _invoke('dk_$fn', native);
      final text = result.toDartString();
      _free(result);
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      if (decoded.containsKey('error')) {
        throw CoreError(decoded['error'] as String);
      }
      return decoded['ok'];
    } finally {
      arena.releaseAll();
    }
  }

  /// Runs a blocking core call (network, ISDS) on a background isolate.
  Future<dynamic> callAsync(String fn, List<Object> args) {
    final dir = dataDir;
    return Isolate.run(() {
      CoreBridge.dataDir = dir;
      return CoreBridge.open()!.call(fn, args);
    });
  }

  _Str _invoke(String symbol, List<Object> a) {
    switch (symbol) {
      case 'dk_login_otp':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, _Str, _Str, Bool),
          _Str Function(_Str, _Str, _Str, _Str, bool)
        >(symbol)(
          a[0] as _Str,
          a[1] as _Str,
          a[2] as _Str,
          a[3] as _Str,
          a[4] as bool,
        );
      case 'dk_login_mep_start':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str),
          _Str Function(_Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str);
      case 'dk_login_mep_poll' ||
          'dk_logout' ||
          'dk_keep_alive' ||
          'dk_set_proxy' ||
          'dk_secret_get':
        return _lib.lookupFunction<_Str Function(_Str), _Str Function(_Str)>(
          symbol,
        )(a[0] as _Str);
      case 'dk_sessions':
        return _lib.lookupFunction<_Str Function(), _Str Function()>(symbol)();
      case 'dk_ai_analyze' || 'dk_ai_cli_prompt' || 'dk_rm_upload':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, Int64, _Str),
          _Str Function(_Str, _Str, int, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as int, a[3] as _Str);
      case 'dk_ai_parse_text' ||
          'dk_check_files' ||
          'dk_rm_settings_get' ||
          'dk_rm_info' ||
          'dk_rm_hierarchy':
        return _lib.lookupFunction<_Str Function(_Str), _Str Function(_Str)>(
          symbol,
        )(a[0] as _Str);
      case 'dk_set_pin' ||
          'dk_rm_settings_set' ||
          'dk_rm_stored' ||
          'dk_secret_set' ||
          'dk_secret_key':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str),
          _Str Function(_Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str);
      case 'dk_mobile_scan':
        return _lib.lookupFunction<_Str Function(_Str), _Str Function(_Str)>(
          symbol,
        )(a[0] as _Str);
      case 'dk_mobile_import' || 'dk_login_cert':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, _Str, _Str),
          _Str Function(_Str, _Str, _Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as _Str, a[3] as _Str);
      case 'dk_backup':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str),
          _Str Function(_Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str);
      case 'dk_restore' ||
          'dk_import_zfo' ||
          'dk_reorder' ||
          'dk_account_add' ||
          'dk_account_remove' ||
          'dk_login_password' ||
          'dk_lock':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, _Str),
          _Str Function(_Str, _Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as _Str);
      case 'dk_op' || 'dk_account_rename' || 'dk_account_set_login':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, _Str, _Str),
          _Str Function(_Str, _Str, _Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as _Str, a[3] as _Str);
      case 'dk_sync' || 'dk_sync_sent':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, _Str),
          _Str Function(_Str, _Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as _Str);
      case 'dk_search':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, _Str, _Str, Bool, Int64),
          _Str Function(_Str, _Str, _Str, _Str, bool, int)
        >(symbol)(
          a[0] as _Str,
          a[1] as _Str,
          a[2] as _Str,
          a[3] as _Str,
          a[4] as bool,
          a[5] as int,
        );
      case 'dk_send':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, _Str),
          _Str Function(_Str, _Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as _Str);
      case 'dk_accounts':
        return _lib.lookupFunction<_Str Function(_Str), _Str Function(_Str)>(
          symbol,
        )(a[0] as _Str);
      case 'dk_messages' || 'dk_message_query':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str),
          _Str Function(_Str, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str);
      case 'dk_attachments':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, Int64),
          _Str Function(_Str, _Str, int)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as int);
      case 'dk_save_attachment':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, Int64, Int64, _Str),
          _Str Function(_Str, _Str, int, int, _Str)
        >(symbol)(
          a[0] as _Str,
          a[1] as _Str,
          a[2] as int,
          a[3] as int,
          a[4] as _Str,
        );
      case 'dk_save_zfo':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, Int64, _Str),
          _Str Function(_Str, _Str, int, _Str)
        >(symbol)(a[0] as _Str, a[1] as _Str, a[2] as int, a[3] as _Str);
      case 'dk_set_read':
        return _lib.lookupFunction<
          _Str Function(_Str, _Str, Int64, Bool, _Str),
          _Str Function(_Str, _Str, int, bool, _Str)
        >(symbol)(
          a[0] as _Str,
          a[1] as _Str,
          a[2] as int,
          a[3] as bool,
          a[4] as _Str,
        );
    }
    throw ArgumentError('unknown core function $symbol');
  }

  /// Opens a file in the system's default application.
  Future<void> openFile(String path) async {
    if (Platform.isIOS) {
      if (!await DataFolder.preview(path)) {
        throw UserError('Soubor se nepodařilo otevřít.');
      }
    } else if (Platform.isAndroid) {
      if (!await AndroidBridge.open(path)) {
        throw UserError('V telefonu není aplikace, která by soubor otevřela.');
      }
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
  }

  String tempPath(String name) {
    final dir = Directory('${Directory.systemTemp.path}/datovka')
      ..createSync(recursive: true);
    final safe = name.replaceAll(RegExp(r'[/\\:]'), '_');
    return '${dir.path}/$safe';
  }

  String get deviceName => Platform.localHostname;
}

class CoreError implements Exception {
  final String message;

  CoreError(this.message);

  @override
  String toString() => message;
}

/// An empty first argument means the open archive. [set_proxy] is the
/// exception: an empty string means the system proxy, not the archive path.
List<Object> argsWithDataDir(String fn, List<Object> args, String dataDir) {
  if (fn == 'set_proxy' ||
      args.isEmpty ||
      args.first != '' ||
      dataDir.isEmpty) {
    return args;
  }
  return [dataDir, ...args.skip(1)];
}
