import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// DateTime extensions
// ---------------------------------------------------------------------------

extension DateTimeExtensions on DateTime {
  /// e.g. "Jan 15, 2025"
  String get formattedDate => DateFormat.yMMMd().format(this);

  /// e.g. "2:30 PM"
  String get formattedTime => DateFormat.jm().format(this);

  /// e.g. "Jan 15, 2025 2:30 PM"
  String get formattedDateTime => '$formattedDate $formattedTime';

  /// e.g. "Jan 15"
  String get shortDate => DateFormat.MMMd().format(this);

  /// Returns "Today", "Yesterday", day-of-week name (within the last 7 days),
  /// or the full formatted date.
  String get relativeDate {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(year, month, day);
    final diff = today.difference(date).inDays;

    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff > 1 && diff < 7) return DateFormat.EEEE().format(this);
    return formattedDate;
  }

  /// Compact time-ago label: "just now", "5m", "2h", "3d", or short date.
  String get timeAgo {
    final now = DateTime.now();
    final diff = now.difference(this);

    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return shortDate;
  }

  bool get isToday {
    final now = DateTime.now();
    return year == now.year && month == now.month && day == now.day;
  }

  bool get isYesterday {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return year == yesterday.year &&
        month == yesterday.month &&
        day == yesterday.day;
  }
}

// ---------------------------------------------------------------------------
// String extensions
// ---------------------------------------------------------------------------

extension StringExtensions on String {
  /// Capitalises the first character, leaves the rest unchanged.
  String get capitalized =>
      isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';

  /// Title-cases each word (split on whitespace).
  String get titleCase =>
      split(RegExp(r'\s+')).map((w) => w.capitalized).join(' ');

  /// Basic email validation.
  bool get isValidEmail => RegExp(r'^[\w.+-]+@[\w-]+\.[\w.]+$').hasMatch(this);

  /// E.164 phone validation (e.g. +14155551234).
  bool get isValidPhone => RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(this);

  /// Truncates the string to [maxLength] characters, appending an ellipsis
  /// if truncation occurred.
  String truncate(int maxLength) {
    if (length <= maxLength) return this;
    return '${substring(0, maxLength)}…';
  }
}

// ---------------------------------------------------------------------------
// BuildContext extensions
// ---------------------------------------------------------------------------

extension ContextExtensions on BuildContext {
  // Theme shortcuts
  ThemeData get theme => Theme.of(this);
  TextTheme get textTheme => Theme.of(this).textTheme;
  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  // Screen dimensions
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  bool get isSmallScreen => screenWidth < 375;
  bool get isMediumScreen => screenWidth >= 375 && screenWidth <= 768;
  bool get isLargeScreen => screenWidth > 768;

  EdgeInsets get viewPadding => MediaQuery.viewPaddingOf(this);

  /// Show a snack bar with an optional error style.
  void showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Show a confirmation dialog. Returns `true` if the user tapped confirm.
  Future<bool> showConfirmDialog({
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
  }) async {
    final result = await showDialog<bool>(
      context: this,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

// ---------------------------------------------------------------------------
// List extensions
// ---------------------------------------------------------------------------

extension ListExtensions<T> on List<T> {
  /// Returns a new list sorted by the value returned from [keyOf].
  List<T> sortedBy<K extends Comparable<K>>(K Function(T) keyOf) {
    return [...this]..sort((a, b) => keyOf(a).compareTo(keyOf(b)));
  }

  /// Returns a new list sorted in descending order by [keyOf].
  List<T> sortedByDescending<K extends Comparable<K>>(K Function(T) keyOf) {
    return [...this]..sort((a, b) => keyOf(b).compareTo(keyOf(a)));
  }

  /// Groups elements by the key returned from [keyOf].
  Map<K, List<T>> groupBy<K>(K Function(T) keyOf) {
    final map = <K, List<T>>{};
    for (final item in this) {
      final key = keyOf(item);
      (map[key] ??= []).add(item);
    }
    return map;
  }
}
