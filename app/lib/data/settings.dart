import 'package:shared_preferences/shared_preferences.dart';

/// Per-device preferences (not synced: each device decides how often it
/// talks to ISDS).
class Settings {
  /// Minutes between automatic downloads; 0 turns it off.
  final int syncMinutes;

  /// Download new messages right after the app starts.
  final bool syncOnStart;

  /// Also mark messages as read in ISDS when opened (the original only marks
  /// them locally).
  final bool markReadInIsds;

  /// Proxy URL; empty uses the system settings.
  final String proxy;

  /// After sending, look into ISDS again shortly until the sent message is
  /// delivered and downloaded, instead of waiting for the next download.
  final bool fetchSentNow;

  const Settings({
    this.syncMinutes = 15,
    this.syncOnStart = true,
    this.markReadInIsds = false,
    this.proxy = '',
    this.fetchSentNow = true,
  });

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    return Settings(
      syncMinutes: p.getInt('syncMinutes') ?? 15,
      syncOnStart: p.getBool('syncOnStart') ?? true,
      markReadInIsds: p.getBool('markReadInIsds') ?? false,
      proxy: p.getString('proxy') ?? '',
      fetchSentNow: p.getBool('fetchSentNow') ?? true,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('syncMinutes', syncMinutes);
    await p.setBool('syncOnStart', syncOnStart);
    await p.setBool('markReadInIsds', markReadInIsds);
    await p.setString('proxy', proxy);
    await p.setBool('fetchSentNow', fetchSentNow);
  }

  Settings copyWith({
    int? syncMinutes,
    bool? syncOnStart,
    bool? markReadInIsds,
    String? proxy,
    bool? fetchSentNow,
  }) => Settings(
    syncMinutes: syncMinutes ?? this.syncMinutes,
    syncOnStart: syncOnStart ?? this.syncOnStart,
    markReadInIsds: markReadInIsds ?? this.markReadInIsds,
    proxy: proxy ?? this.proxy,
    fetchSentNow: fetchSentNow ?? this.fetchSentNow,
  );
}
