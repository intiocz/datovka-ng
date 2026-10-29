import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps access to the folder the user picked on iOS. Without a bookmark the
/// system forgets the permission and the phone cannot open the same archive
/// as the computer after a restart.
class DataFolder {
  static const _channel = MethodChannel('cz.datovka/folder');

  static Future<String?> restore() async {
    if (!Platform.isIOS) return null;
    try {
      final path = await _channel.invokeMethod<String>('resolve');
      if (path == null || path.isEmpty) return null;
      return path;
    } on Object {
      return null;
    }
  }

  /// Brings the archive files from iCloud Drive onto the phone; returns how
  /// many are still missing (0 off iOS or when everything is there).
  static Future<int> materialize(String path) async {
    if (!Platform.isIOS || path.isEmpty) return 0;
    try {
      return await _channel.invokeMethod<int>('materialize', path) ?? 0;
    } on Object {
      return 0;
    }
  }

  /// Shows a file in Quick Look on iOS. False when it could not.
  static Future<bool> preview(String path) async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('preview', path) ?? false;
    } on Object {
      return false;
    }
  }

  /// Adds events to the iPhone calendar; how many were added, -1 when the
  /// calendar is not allowed.
  static Future<int> addToCalendar(List<Map<String, Object>> events) async {
    return await _channel.invokeMethod<int>('calendar', events) ?? 0;
  }

  static Future<String?> documents() async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('documents');
    } on Object {
      return null;
    }
  }

  static Future<void> remember(String path) async {
    if (!Platform.isIOS || path.isEmpty) return;
    try {
      await _channel.invokeMethod('store', path);
    } on Object {
      // The plain path is still saved. Access lasts for this run.
    }
  }
}
