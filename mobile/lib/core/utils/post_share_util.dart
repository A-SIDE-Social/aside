import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/post.dart';
import '../config/env.dart';

/// Utility for sharing posts to external platforms via the native share sheet.
///
/// Flow: user taps share → bottom sheet opens with "Copy caption" + share
/// options. Caption is auto-copied to clipboard on open so the user can paste
/// it into the target app. Media is shared without text attached (most
/// platforms silently drop share-intent text anyway).
class PostShareUtil {
  /// Build 39: in-flight guard. Prevents stacked iOS share sheets if
  /// the user double-taps the share button OR if a previous share
  /// hasn't fully dismissed. Particularly defensive against the
  /// known iOS quirk where Instagram's share extension shows a
  /// Reel/Story/Post chooser without firing UIActivityViewController's
  /// completion callback — leaving the iOS share sheet visible
  /// behind Instagram. Without this guard, a second tap stacks
  /// another sheet on top of the lingering one.
  ///
  /// Reset in `_endShare` (in finally blocks of the share methods)
  /// so a thrown error doesn't lock the share button forever.
  static bool _sharing = false;

  /// Share a post. Copies caption to clipboard (toast confirmation), then
  /// either goes straight to the share sheet (single media) or shows a
  /// bottom sheet for carousel choice.
  static Future<void> share(
    BuildContext context,
    Post post, {
    int mediaIndex = 0,
  }) async {
    if (_sharing) return; // double-tap guard, see comment above
    _sharing = true;
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin =
          box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero;

      final shareText = buildShareText(post);

      if (post.media.isEmpty) {
        await _shareTextPost(context, shareText, post.caption ?? '', origin);
        return;
      }

      // Copy caption to clipboard before opening the share sheet.
      Clipboard.setData(ClipboardData(text: shareText));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Caption copied to clipboard'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      if (post.media.length == 1) {
        // Single media — straight to share sheet, no extra tap
        await _shareMedia(context, [post.media[0]], origin);
      } else {
        if (!context.mounted) return;
        // Awaited so the in-flight guard stays held until the
        // carousel sheet is dismissed AND the resulting share
        // (if any) finishes — a double-tap during the carousel
        // chooser shouldn't stack a second sheet.
        await _showCarouselShareSheet(context, post, mediaIndex, origin);
      }
    } finally {
      _sharing = false;
    }
  }

  /// Shows a bottom sheet for carousel posts: share this photo or share all.
  /// Returns when the sheet (and any subsequent native share) is dismissed,
  /// so the caller's `_sharing` guard can release at the right time.
  static Future<void> _showCarouselShareSheet(
    BuildContext context,
    Post post,
    int mediaIndex,
    Rect origin,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Share this photo'),
              onTap: () async {
                Navigator.pop(ctx);
                await _shareMedia(context, [post.media[mediaIndex]], origin);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text('Share all ${post.media.length} photos'),
              onTap: () async {
                Navigator.pop(ctx);
                await _shareMedia(context, post.media, origin);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Builds the share text for a post (caption + branding).
  @visibleForTesting
  static String buildShareText(Post post) {
    final parts = <String>[];
    if (post.caption != null && post.caption!.isNotEmpty) {
      parts.add(post.caption!);
    }
    parts.add('Shared from ${Env.appName}');
    return parts.join('\n\n');
  }

  /// Share one or more media items as-is (no text attached).
  static Future<void> _shareMedia(
    BuildContext context,
    List<PostMedia> mediaList,
    Rect origin,
  ) async {
    try {
      final xFiles = <XFile>[];

      for (var i = 0; i < mediaList.length; i++) {
        final media = mediaList[i];
        final file = await DefaultCacheManager().getSingleFile(media.mediaUrl);
        final isVideo = media.mediaType == 'video';

        xFiles.add(
          XFile(
            file.path,
            mimeType: isVideo ? 'video/mp4' : 'image/jpeg',
            name: mediaList.length == 1
                ? 'post.${isVideo ? 'mp4' : 'jpg'}'
                : 'post_${i + 1}.${isVideo ? 'mp4' : 'jpg'}',
          ),
        );
      }

      // share_plus 12 introduced SharePlus.instance.share(ShareParams)
      // as the non-deprecated API. Migrating gets us the v12.0.0 iOS
      // fix ("unable to get correct result on iOS") on the path that
      // actually receives the result back from UIActivityViewController.
      // The v12.0.1 fix for iPhones-without-sharePositionOrigin and
      // v12.0.2 add-to-app crash fix come along too.
      await SharePlus.instance.share(
        ShareParams(
          files: xFiles,
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't prepare post for sharing")),
        );
      }
    }
  }

  /// Share a text-only post by rendering a styled image card.
  static Future<void> _shareTextPost(
    BuildContext context,
    String shareText,
    String caption,
    Rect origin,
  ) async {
    // Auto-copy caption to clipboard for text posts too
    Clipboard.setData(ClipboardData(text: shareText));

    try {
      final brightness = Theme.of(context).brightness;
      final imagePath = await _renderTextCard(
        text: caption,
        brightness: brightness,
      );

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(imagePath, mimeType: 'image/png', name: 'post.png')],
          sharePositionOrigin: origin,
        ),
      );

      try {
        await File(imagePath).delete();
      } catch (_) {}
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't prepare post for sharing")),
        );
      }
    }
  }

  /// Renders a styled text card as an image and returns the temp file path.
  static Future<String> _renderTextCard({
    required String text,
    required Brightness brightness,
  }) async {
    final isDark = brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFAFAFA);
    final textColor =
        isDark ? const Color(0xFFFAFAFA) : const Color(0xFF0A0A0A);
    final subtleColor =
        isDark ? const Color(0xFF666666) : const Color(0xFF999999);

    const cardWidth = 1080.0;
    const cardHeight = 1080.0;

    final widget = MediaQuery(
      data: const MediaQueryData(devicePixelRatio: 1),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          width: cardWidth,
          height: cardHeight,
          color: bgColor,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 80,
                    vertical: 80,
                  ),
                  child: Center(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: text.length > 140 ? 36 : 48,
                        fontWeight: FontWeight.w500,
                        color: textColor,
                        height: 1.4,
                        fontFamily: 'Geist',
                        decoration: TextDecoration.none,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 48),
                child: Text(
                  Env.appName,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: subtleColor,
                    letterSpacing: 2,
                    fontFamily: 'Geist',
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final repaintBoundary = RenderRepaintBoundary();
    final view = ui.PlatformDispatcher.instance.implicitView!;
    final renderView = RenderView(
      view: view,
      child: RenderPositionedBox(
        alignment: Alignment.center,
        child: repaintBoundary,
      ),
      configuration: ViewConfiguration(
        logicalConstraints: const BoxConstraints.tightFor(
          width: cardWidth,
          height: cardHeight,
        ),
        devicePixelRatio: 1,
      ),
    );

    final pipelineOwner = PipelineOwner();
    pipelineOwner.rootNode = renderView;
    renderView.prepareInitialFrame();

    final buildOwner = BuildOwner(focusManager: FocusManager());
    final rootElement = RenderObjectToWidgetAdapter<RenderBox>(
      container: repaintBoundary,
      child: widget,
    ).attachToRenderTree(buildOwner);

    buildOwner.buildScope(rootElement);
    pipelineOwner.flushLayout();
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();

    final image = await repaintBoundary.toImage(pixelRatio: 1);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    buildOwner.finalizeTree();

    final bytes = byteData!.buffer.asUint8List();
    final tempDir = Directory.systemTemp;
    final file = File(
        '${tempDir.path}/aside_post_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);

    return file.path;
  }
}
