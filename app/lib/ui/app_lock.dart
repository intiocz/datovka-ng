import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// Locks the app on a phone with Face ID, Touch ID or the phone's code: at
/// launch and whenever it comes back from the background. Off by default.
class AppLock extends StatefulWidget {
  final Widget child;

  const AppLock({super.key, required this.child});

  static const _pref = 'appLock';

  /// Phones only; a computer has its own login and screen lock.
  static bool get available => Platform.isIOS || Platform.isAndroid;

  static final enabled = ValueNotifier<bool>(false);

  static Future<void> load() async {
    if (!available) return;
    enabled.value =
        (await SharedPreferences.getInstance()).getBool(_pref) ?? false;
  }

  /// Turning it on asks once right away, so nobody locks themselves out
  /// on a phone without Face ID or a code.
  static Future<void> setEnabled(bool on) async {
    if (on) {
      if (!await LocalAuthPlatform.instance.isDeviceSupported()) {
        throw const _LockError(
          'Telefon nemá nastavený kód ani Face ID, není čím zamykat.',
        );
      }
      if (!await _ask()) return;
    }
    await (await SharedPreferences.getInstance()).setBool(_pref, on);
    enabled.value = on;
  }

  /// Straight to the iOS and Android parts of local_auth: its Windows part
  /// does not build with current Visual Studio, and a computer needs none.
  static Future<bool> _ask() async {
    try {
      return await LocalAuthPlatform.instance.authenticate(
        localizedReason: 'Odemknout Datovku',
        authMessages: const [IOSAuthMessages(), AndroidAuthMessages()],
        options: const AuthenticationOptions(
          stickyAuth: true,
          useErrorDialogs: false,
        ),
      );
    } on Object {
      // Cancelled, locked out, or no plugin: stay locked, the button retries.
      return false;
    }
  }

  @override
  State<AppLock> createState() => _AppLockState();
}

class _LockError implements Exception {
  final String message;

  const _LockError(this.message);

  @override
  String toString() => message;
}

class _AppLockState extends State<AppLock> with WidgetsBindingObserver {
  late var _locked = AppLock.enabled.value;
  var _asking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!AppLock.enabled.value) return;
    // Face ID itself only makes the app inactive; leaving it pauses it.
    if (state == AppLifecycleState.paused) {
      setState(() => _locked = true);
    } else if (state == AppLifecycleState.resumed && _locked) {
      _unlock();
    }
  }

  Future<void> _unlock() async {
    if (_asking) return;
    _asking = true;
    final ok = await AppLock._ask();
    _asking = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    return Stack(
      children: [
        // The app stays as it was underneath, just hidden.
        Offstage(offstage: _locked, child: widget.child),
        if (_locked)
          Positioned.fill(
            child: Material(
              color: t.paper,
              child: SafeArea(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline, size: 40, color: t.inkMuted),
                      const SizedBox(height: 16),
                      Text('Datovka je zamčená', style: text.titleMedium),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _unlock,
                        icon: const Icon(Icons.face_outlined, size: 18),
                        label: const Text('Odemknout'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
