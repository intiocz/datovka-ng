import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

/// Per-device preferences (not synced: each device decides how often it
/// talks to ISDS).
class Settings {
  /// Minutes between automatic downloads; 0 downloads only on request (the
  /// default: ISDS wants desktop apps to log in when the user says so).
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

  /// Text size: -1 a little smaller, 0 as designed, 1 a little larger.
  final int textSize;

  /// Light or dark look, or as the system has it.
  final ThemeMode themeMode;

  /// Folder for automatic backups; empty turns them off.
  final String backupDir;

  /// Days between automatic backups.
  final int backupDays;

  /// How many automatic backups to keep; older ones are deleted.
  final int backupKeep;

  /// How much [textSize] scales the text.
  double get textScale => const [0.92, 1.0, 1.08][textSize.clamp(-1, 1) + 1];

  const Settings({
    this.syncMinutes = 0,
    this.syncOnStart = true,
    this.markReadInIsds = false,
    this.proxy = '',
    this.fetchSentNow = true,
    this.textSize = 0,
    this.themeMode = ThemeMode.system,
    this.backupDir = '',
    this.backupDays = 1,
    this.backupKeep = 7,
  });

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    return Settings(
      syncMinutes: p.getInt('syncMinutes') ?? 0,
      syncOnStart: p.getBool('syncOnStart') ?? true,
      markReadInIsds: p.getBool('markReadInIsds') ?? false,
      proxy: p.getString('proxy') ?? '',
      fetchSentNow: p.getBool('fetchSentNow') ?? true,
      textSize: p.getInt('textSize') ?? 0,
      themeMode: ThemeMode.values.asNameMap()[p.getString('themeMode')] ??
          ThemeMode.system,
      backupDir: p.getString('backupDir') ?? '',
      backupDays: p.getInt('backupDays') ?? 1,
      backupKeep: p.getInt('backupKeep') ?? 7,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('syncMinutes', syncMinutes);
    await p.setBool('syncOnStart', syncOnStart);
    await p.setBool('markReadInIsds', markReadInIsds);
    await p.setString('proxy', proxy);
    await p.setBool('fetchSentNow', fetchSentNow);
    await p.setInt('textSize', textSize);
    await p.setString('themeMode', themeMode.name);
    await p.setString('backupDir', backupDir);
    await p.setInt('backupDays', backupDays);
    await p.setInt('backupKeep', backupKeep);
  }

  Settings copyWith({
    int? syncMinutes,
    bool? syncOnStart,
    bool? markReadInIsds,
    String? proxy,
    bool? fetchSentNow,
    int? textSize,
    ThemeMode? themeMode,
    String? backupDir,
    int? backupDays,
    int? backupKeep,
  }) => Settings(
    syncMinutes: syncMinutes ?? this.syncMinutes,
    syncOnStart: syncOnStart ?? this.syncOnStart,
    markReadInIsds: markReadInIsds ?? this.markReadInIsds,
    proxy: proxy ?? this.proxy,
    fetchSentNow: fetchSentNow ?? this.fetchSentNow,
    textSize: textSize ?? this.textSize,
    themeMode: themeMode ?? this.themeMode,
    backupDir: backupDir ?? this.backupDir,
    backupDays: backupDays ?? this.backupDays,
    backupKeep: backupKeep ?? this.backupKeep,
  );
}
