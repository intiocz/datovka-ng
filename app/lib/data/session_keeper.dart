import 'dart:async';

import 'package:flutter/widgets.dart';

import 'models.dart';

/// Keeps logins that need the user at hand (SMS, code from an app, mobile
/// key) alive, like the original Datovka since 4.25: every 25 minutes one
/// request that does nothing. ISDS ends such a session after 30 minutes
/// without a request. The request (`DummyOperation`) delivers nothing; only
/// the list of received messages counts as logging in to the box.
class SessionKeeper {
  static const interval = Duration(minutes: 25);

  /// `true` alive, `false` ISDS ended the session, `null` not known now
  /// (no network): the session is kept and asked again next time.
  final Future<bool?> Function(String username) ping;
  final List<DataBox> Function() boxes;
  final void Function(DataBox box) expired;

  Timer? _timer;
  AppLifecycleListener? _life;

  SessionKeeper({
    required this.ping,
    required this.boxes,
    required this.expired,
  });

  /// Boxes whose session needs keeping.
  static List<DataBox> targets(List<DataBox> boxes) => [
    for (final b in boxes)
      if (b.login.interactive && b.session == Session.active) b,
  ];

  /// Starts the timer. A phone in the background does nothing; back in
  /// front it asks at once, so a session that ended meanwhile shows so.
  void start() {
    stop();
    _timer = Timer.periodic(interval, (_) => tick());
    _life = AppLifecycleListener(
      onPause: () => _timer?.cancel(),
      onResume: () {
        _timer?.cancel();
        _timer = Timer.periodic(interval, (_) => tick());
        tick();
      },
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _life?.dispose();
    _life = null;
  }

  Future<void> tick() async {
    for (final b in targets(boxes())) {
      try {
        if (await ping(b.username) == false) expired(b);
      } on Object {
        // Not known now; the next tick or call tells.
      }
    }
  }
}
