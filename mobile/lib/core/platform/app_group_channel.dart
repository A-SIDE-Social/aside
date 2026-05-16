import 'dart:io';
import 'package:flutter/services.dart';

/// Platform channel for sharing data with iOS Share Extension and Widget
/// via App Group container files.
class AppGroupChannel {
  static const _channel = MethodChannel('com.lab1908.instadamn/app_group');

  /// Sync the auth token to App Group container so extensions can use it.
  static Future<void> setToken(String token) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setToken', token);
    } catch (_) {}
  }

  /// Sync the API base URL to App Group container.
  static Future<void> setApiBaseUrl(String url) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setApiBaseUrl', url);
    } catch (_) {}
  }

  /// Sync the user ID to App Group container for own-post filtering.
  static Future<void> setUserId(String userId) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setUserId', userId);
    } catch (_) {}
  }

  /// Clear the auth token from App Group container (on logout).
  static Future<void> clearToken() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('clearToken');
    } catch (_) {}
  }

  /// Read the user ID from App Group container.
  static Future<String?> getUserId() async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('getUserId');
    } catch (_) {
      return null;
    }
  }

  /// Cache the latest feed image and poster name for the widget.
  static Future<void> cacheWidgetImage(
      String imageUrl, String posterName) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('cacheWidgetImage', {
        'imageUrl': imageUrl,
        'posterName': posterName,
      });
    } catch (_) {}
  }

  /// Tell WidgetKit to reload all widget timelines.
  static Future<void> reloadWidgets() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('reloadWidgets');
    } catch (_) {}
  }
}
