import 'package:flutter/material.dart';

class AppColorTokens {
  final Color surface;
  final Color surfaceAlt;
  final Color card;
  final Color cardHover;
  final Color border;
  final Color borderSubtle;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;

  /// Background for own DM bubbles (right side). Intentionally subtle —
  /// a small step above the screen background, NOT the high-contrast
  /// inverted-text-color treatment we used in the past. The asymmetry
  /// vs `bubbleOther` is what carries the "this one is mine" reading.
  final Color bubbleOwn;

  /// Background for other DM bubbles (left side). Slightly less
  /// emphasized than [bubbleOwn] so own messages still stand out, but
  /// both sit gently above the page so the conversation reads as a
  /// quiet exchange rather than a stark contrast battle.
  final Color bubbleOther;

  const AppColorTokens({
    required this.surface,
    required this.surfaceAlt,
    required this.card,
    required this.cardHover,
    required this.border,
    required this.borderSubtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.bubbleOwn,
    required this.bubbleOther,
  });
}

class AppColors {
  AppColors._();

  // Semantic
  static const error = Color(0xFFFF6B6B);
  static const success = Color(0xFF7ECBA1);
  static const warning = Color(0xFFF2C66D);

  // Dark mode
  static const darkSurface = Color(0xFF0A0A0A);
  static const darkSurfaceAlt = Color(0xFF141414);
  static const darkCard = Color(0xFF1A1A1A);
  static const darkCardHover = Color(0xFF222222);
  static const darkBorder = Color(0xFF333333);
  static const darkBorderSubtle = Color(0xFF262626);
  static const darkTextPrimary = Color(0xFFFFFFFF);
  static const darkTextSecondary = Color(0xFFC8C8C8);
  static const darkTextTertiary = Color(0xFF919191);
  static const darkAccent = Color(0xFFFFFFFF);
  // Two soft greys above the dark surface (#0A0A0A). Own is a touch
  // brighter so it reads as "the one I sent" without the previous
  // pure-white-on-black slap to the eye.
  static const darkBubbleOwn = Color(0xFF262626);
  static const darkBubbleOther = Color(0xFF181818);

  // Light mode
  static const lightSurface = Color(0xFFFAFAFA);
  static const lightSurfaceAlt = Color(0xFFEDEDED);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightCardHover = Color(0xFFF3F3F3);
  static const lightBorder = Color(0xFFCCCCCC);
  static const lightBorderSubtle = Color(0xFFDDDDDD);
  static const lightTextPrimary = Color(0xFF050505);
  static const lightTextSecondary = Color(0xFF3A3A3A);
  static const lightTextTertiary = Color(0xFF666666);
  static const lightAccent = Color(0xFF050505);
  // Both bubble colors sit slightly DARKER than the light surface
  // (#FAFAFA) so the bubbles read as "indented panes" rather than
  // floating cards. Own is a touch deeper than other.
  static const lightBubbleOwn = Color(0xFFE8E8E8);
  static const lightBubbleOther = Color(0xFFF1F1F1);

  static const _dark = AppColorTokens(
    surface: darkSurface,
    surfaceAlt: darkSurfaceAlt,
    card: darkCard,
    cardHover: darkCardHover,
    border: darkBorder,
    borderSubtle: darkBorderSubtle,
    textPrimary: darkTextPrimary,
    textSecondary: darkTextSecondary,
    textTertiary: darkTextTertiary,
    accent: darkAccent,
    bubbleOwn: darkBubbleOwn,
    bubbleOther: darkBubbleOther,
  );

  static const _light = AppColorTokens(
    surface: lightSurface,
    surfaceAlt: lightSurfaceAlt,
    card: lightCard,
    cardHover: lightCardHover,
    border: lightBorder,
    borderSubtle: lightBorderSubtle,
    textPrimary: lightTextPrimary,
    textSecondary: lightTextSecondary,
    textTertiary: lightTextTertiary,
    accent: lightAccent,
    bubbleOwn: lightBubbleOwn,
    bubbleOther: lightBubbleOther,
  );

  static AppColorTokens of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? _dark : _light;
  }
}
