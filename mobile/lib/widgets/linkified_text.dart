import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'in_app_browser.dart';

/// A Text widget that detects URLs and makes them tappable.
/// Opens links in an in-app WebView.
class LinkifiedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const LinkifiedText({
    super.key,
    required this.text,
    this.style,
    this.linkStyle,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  static final _urlRegex = RegExp(
    r'https?://[^\s<>\[\]{}|\\^`"]+',
    caseSensitive: false,
  );

  /// Builds the URL-detecting InlineSpans for [text]. Exposed so other
  /// widgets can compose the output with extra prefix/suffix spans
  /// (e.g. the `@{name}` reply prefix in the comments sheet) while
  /// still keeping URL detection on the rest of the body.
  static List<InlineSpan> buildSpans(
    BuildContext context,
    String text, {
    TextStyle? style,
    TextStyle? linkStyle,
  }) {
    final defaultStyle = style ?? DefaultTextStyle.of(context).style;
    final defaultLinkStyle = linkStyle ??
        defaultStyle.copyWith(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor:
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
        );

    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: text, style: defaultStyle)];
    }

    final spans = <InlineSpan>[];
    var lastEnd = 0;
    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: defaultStyle,
        ));
      }
      final url = match.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: defaultLinkStyle,
        recognizer: TapGestureRecognizer()
          ..onTap = () => InAppBrowser.open(context, url),
      ));
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: defaultStyle,
      ));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final defaultStyle = style ?? DefaultTextStyle.of(context).style;

    // Fast path: no URL detection needed, avoid a RichText allocation.
    if (!_urlRegex.hasMatch(text)) {
      return Text(
        text,
        style: defaultStyle,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }

    return RichText(
      text: TextSpan(
        children: buildSpans(
          context,
          text,
          style: defaultStyle,
          linkStyle: linkStyle,
        ),
      ),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      textAlign: textAlign ?? TextAlign.start,
    );
  }
}
