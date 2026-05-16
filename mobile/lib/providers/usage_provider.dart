import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks daily app usage time in seconds.
/// Stored in SharedPreferences keyed by date (yyyy-MM-dd).
///
/// Riverpod 3 Notifier — `build()` returns the synchronous initial value
/// (0), kicks off the background load + session ticker, and registers a
/// dispose hook so the timer is cancelled and the latest value flushed
/// to SharedPreferences when the provider is torn down.
class UsageNotifier extends Notifier<int> {
  Timer? _timer;
  static const _prefix = 'usage_';

  @override
  int build() {
    _loadToday();
    startSession();
    ref.onDispose(() {
      _timer?.cancel();
      _persist();
    });
    return 0;
  }

  String get _todayKey => _prefix + _todayDate();

  static String _todayDate() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadToday() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt(_todayKey) ?? 0;
  }

  void startSession() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      state += 1;
      // Persist every 10 seconds to avoid excessive writes
      if (state % 10 == 0) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_todayKey, state);
      }
    });
  }

  void pauseSession() {
    _timer?.cancel();
    _timer = null;
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_todayKey, state);
  }

  /// Get usage for the last N days (including today).
  Future<Map<String, int>> getHistory({int days = 7}) async {
    final prefs = await SharedPreferences.getInstance();
    final result = <String, int>{};
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      final date = now.subtract(Duration(days: i));
      final key =
          '$_prefix${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      result[key.replaceFirst(_prefix, '')] = prefs.getInt(key) ?? 0;
    }
    return result;
  }
}

final usageProvider = NotifierProvider<UsageNotifier, int>(UsageNotifier.new);

/// Format seconds into a human-readable string.
String formatUsageTime(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (remainingMinutes == 0) return '${hours}h';
  return '${hours}h ${remainingMinutes}m';
}
