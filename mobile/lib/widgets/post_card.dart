import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../core/cache/image_cache_manager.dart';
import '../core/config/app_colors.dart';
import '../core/config/constants.dart';
import '../core/utils/emoji_picker.dart';
import '../core/utils/post_share_util.dart';
import '../models/post.dart';
import 'avatar.dart';
import 'comments_sheet.dart';
import 'feed_pinch_zoom.dart';
import 'likes_sheet.dart';
import 'linkified_text.dart';
import 'reactions_strip.dart';

class PostCard extends StatefulWidget {
  final Post post;
  final VoidCallback? onTap;
  final VoidCallback? onUserTap;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onEditCaption;
  final VoidCallback? onLike;

  /// Toggle an emoji reaction on this post. Caller handles
  /// optimistic update + API call. When null, the reactions strip
  /// and the "+" emoji picker are both suppressed (e.g. on surfaces
  /// where reactions don't make sense).
  final ValueChanged<String>? onReact;
  final bool isOwn;
  final bool showCommentButton;

  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onUserTap,
    this.onDelete,
    this.onEditCaption,
    this.onLike,
    this.onReact,
    this.isOwn = false,
    this.showCommentButton = false,
  });

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard>
    with SingleTickerProviderStateMixin {
  int _currentPage = 0;
  bool _captionExpanded = false;

  // Heart-overlay animation triggered by double-tap-to-like on the
  // photo. Pop-in (scale 0.4 → 1.2 with overshoot ease), settle
  // (1.2 → 1.0), hold, then fade out. Total ~700 ms — long enough
  // to register, short enough not to block scrolling.
  late final AnimationController _heartCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _heartScale = TweenSequence<double>([
    TweenSequenceItem(
      tween:
          Tween(begin: 0.4, end: 1.25).chain(CurveTween(curve: Curves.easeOut)),
      weight: 25,
    ),
    TweenSequenceItem(
      tween:
          Tween(begin: 1.25, end: 1.0).chain(CurveTween(curve: Curves.easeIn)),
      weight: 15,
    ),
    TweenSequenceItem(
      tween: ConstantTween(1.0),
      weight: 35,
    ),
    TweenSequenceItem(
      tween:
          Tween(begin: 1.0, end: 1.15).chain(CurveTween(curve: Curves.easeOut)),
      weight: 25,
    ),
  ]).animate(_heartCtrl);
  late final Animation<double> _heartOpacity = TweenSequence<double>([
    TweenSequenceItem(
      tween:
          Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOut)),
      weight: 15,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
    TweenSequenceItem(
      tween:
          Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeIn)),
      weight: 25,
    ),
  ]).animate(_heartCtrl);

  @override
  void dispose() {
    _heartCtrl.dispose();
    super.dispose();
  }

  /// Double-tap on the photo: like the post (only — never unlike, per
  /// IG conventions) and play the heart overlay animation. The
  /// animation plays even if already-liked so the gesture always feels
  /// acknowledged. Idempotent: parent's onLike (if it would toggle off
  /// when isLiked) is suppressed here so a double-tap on a liked post
  /// doesn't accidentally remove the like.
  void _onDoubleTapLike() {
    if (!widget.post.isLiked && widget.onLike != null) {
      widget.onLike!();
    }
    _heartCtrl.forward(from: 0);
  }

  /// Heart icon that pops in over the photo on double-tap-to-like.
  /// White with a soft black drop shadow so it stays legible on any
  /// photo (bright sky, dark portrait). Sits at status=dismissed by
  /// default — only takes pixels when the controller has fired.
  Widget _buildHeartOverlay() {
    return AnimatedBuilder(
      animation: _heartCtrl,
      builder: (context, _) {
        if (_heartCtrl.status == AnimationStatus.dismissed) {
          return const SizedBox.shrink();
        }
        return Opacity(
          opacity: _heartOpacity.value,
          child: Transform.scale(
            scale: _heartScale.value,
            child: const Icon(
              Icons.favorite_rounded,
              color: Colors.white,
              size: 110,
              shadows: [
                Shadow(
                  blurRadius: 28,
                  color: Colors.black54,
                  offset: Offset(0, 4),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final post = widget.post;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        GestureDetector(
          onTap: widget.onUserTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Avatar(
                  imageUrl: post.avatarUrl,
                  displayName: post.displayName,
                  size: 32,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    post.displayName,
                    style: theme.textTheme.labelLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _timeAgo(post.createdAt),
                  style: theme.textTheme.bodySmall,
                ),
                // Three-dot menu — own posts only. Always shown when
                // isOwn (gate no longer depends on onDelete/onEdit
                // being wired) because the menu now always contains
                // Share, which doesn't need those callbacks.
                if (widget.isOwn) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => _showActionSheet(context),
                    child: Icon(
                      Icons.more_horiz,
                      size: 20,
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Media or text-only post
        if (post.media.isNotEmpty)
          _buildMedia(colors)
        else if (post.caption != null && post.caption!.isNotEmpty)
          // Text-only post: large centered text
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: SizedBox(
              width: double.infinity,
              child: LinkifiedText(
                text: post.caption!,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        // Action row — heart (+ count), comment, share. Left-aligned
        // below the content (media or text) to match Instagram's layout
        // and add breathing room above the caption. Rendered for text
        // posts too; like/comment/share all work on media-less posts
        // (PostShareUtil renders text posts as a 1080×1080 PNG card).
        //
        // Icon glyphs each have a different optical center inside their
        // 24×24 box: the comment bubble's tail and the iOS share's arrow
        // tip would otherwise make the row look uneven. We pick a
        // tail-less comment bubble and pull the share icon up ~2px so
        // the three glyphs sit on a shared visual baseline.
        if (widget.onLike != null ||
            widget.showCommentButton ||
            widget.onReact != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            // Final action-row layout (1.2):
            //   [Heart][count] [reactions strip ─scroll─] [+] [Comment]
            //   pinned left   takes remaining width      pinned right
            //
            // Reactions strip uses Expanded so it absorbs whatever
            // horizontal slack exists between the fixed-width left
            // group (heart + count) and right group (+ + comment).
            // The strip itself scrolls horizontally if many emojis
            // overflow. The "+" stays visible — it's NOT inside the
            // scroll, so users always see how to react.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.onLike != null) ...[
                  // Heart icon — tap toggles like, long-press shows
                  // the LikesSheet (preserved for users who already
                  // know the gesture).
                  _ActionButton(
                    icon: post.isLiked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color:
                        post.isLiked ? AppColors.error : colors.textSecondary,
                    onTap: widget.onLike,
                    onLongPress: () => showPostLikesSheet(context, post.id),
                  ),
                  // Tappable count chip — single tap opens the
                  // LikesSheet, making the previously-invisible
                  // long-press affordance discoverable. Only shown
                  // when there's at least one like.
                  if (post.likeCount > 0)
                    _LikeCountChip(
                      count: post.likeCount,
                      color:
                          post.isLiked ? AppColors.error : colors.textSecondary,
                      onTap: () => showPostLikesSheet(context, post.id),
                    ),
                ],
                // Reactions strip — takes the middle. Empty list
                // collapses to zero width, which is fine because the
                // "+" pill below is always present and serves as the
                // entry point even when no reactions exist yet.
                if (widget.onReact != null) ...[
                  const SizedBox(width: 4),
                  Expanded(
                    child: ReactionsStrip(
                      postId: post.id,
                      reactions: post.reactions,
                      onToggle: widget.onReact!,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // "+" emoji picker entry. Pinned right of the
                  // scrollable strip so it's always visible, never
                  // hidden behind scroll.
                  _AddReactionButton(
                    color: colors.textSecondary,
                    onTap: () async {
                      final picked = await pickEmoji(context);
                      if (picked != null && context.mounted) {
                        widget.onReact!(picked);
                      }
                    },
                  ),
                ] else
                  const Spacer(),
                if (widget.showCommentButton)
                  _ActionButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    color: colors.textSecondary,
                    iconOffsetY: 1.5,
                    onTap: () => showCommentsSheet(context, post.id),
                    label:
                        post.commentCount > 0 ? '${post.commentCount}' : null,
                  ),
                // Share moved to the post's three-dot menu (own posts
                // only — see _showActionSheet).
              ],
            ),
          ),

        // Caption — full-width row below the action row (media posts only;
        // text-only posts already render their caption as the main content).
        // Top padding is intentionally 0 — the action row's _ActionButton
        // padding already supplies all the breathing room we want above the
        // caption text. Adding more here makes the card feel disconnected.
        if (post.media.isNotEmpty &&
            post.caption != null &&
            post.caption!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: GestureDetector(
              onTap: () {
                if (!_captionExpanded) {
                  setState(() => _captionExpanded = true);
                }
              },
              child: _captionExpanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinkifiedText(
                          text: post.caption!,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 2),
                        GestureDetector(
                          onTap: () => setState(() => _captionExpanded = false),
                          child: Text(
                            'Show less',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    )
                  : _buildTruncatedCaption(post.caption!, theme, colors),
            ),
          ),

        // Inline comment previews + "View all" link were removed in
        // build 30 — the comment count on the action-row icon is the
        // only entry point to the sheet now, matching Instagram's
        // pattern. Keeps the feed scannable and stops the card from
        // stretching when a thread gets long.
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildTruncatedCaption(
      String caption, ThemeData theme, AppColorTokens colors) {
    const maxLines = 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textSpan =
            TextSpan(text: caption, style: theme.textTheme.bodyMedium);
        final tp = TextPainter(
          text: textSpan,
          maxLines: maxLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        if (tp.didExceedMaxLines) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinkifiedText(
                text: caption,
                style: theme.textTheme.bodyMedium,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'Read more',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textTertiary,
                ),
              ),
            ],
          );
        }
        return LinkifiedText(
          text: caption,
          style: theme.textTheme.bodyMedium,
        );
      },
    );
  }

  Widget _buildMediaItem(
    PostMedia item,
    AppColorTokens colors, {
    VoidCallback? onTap,
    VoidCallback? onDoubleTap,
    BoxFit fit = BoxFit.cover,
  }) {
    if (item.mediaType == 'video') {
      // If onTap is set (feed/grid), show static thumbnail with play
      // icon — tap navigates to detail. If we have a pre-extracted
      // thumbnail URL (client-uploaded first frame), use it directly
      // via CachedNetworkImage — much cheaper than loading the full
      // mp4 just to paint frame 0. Fall back to the live-initialize
      // path for legacy videos without a stored thumbnail.
      //
      // If no onTap (detail screen), show the interactive video player
      // regardless — the detail screen is where the video is meant to
      // actually play.
      if (onTap != null) {
        final thumb = item.thumbnailUrl;
        if (thumb != null && thumb.isNotEmpty) {
          return GestureDetector(
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CachedNetworkImage(
                    imageUrl: thumb,
                    fit: BoxFit.cover,
                    cacheManager: AppImageCacheManager.instance,
                    placeholder: (_, __) => Container(color: colors.surfaceAlt),
                    errorWidget: (_, __, ___) => _VideoStaticThumbnail(
                        url: item.mediaUrl, colors: colors),
                  ),
                ),
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black54,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 36,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          );
        }
        return GestureDetector(
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          child: _VideoStaticThumbnail(url: item.mediaUrl, colors: colors),
        );
      }
      return _VideoThumbnail(url: item.mediaUrl, colors: colors);
    }
    // No memCacheWidth: decode at source resolution. Capping below
    // source (previously screenWidth × DPR ≈ 1179px on a 15 Pro Max)
    // was the dominant cause of soft feed images. At 1800px source,
    // RAM impact is modest; Flutter's ImageCache evicts under pressure.
    //
    // FeedPinchZoom adds IG-style pinch-to-peek-and-release. It only
    // activates on 2+ pointers so single-finger tap (onTap) and the
    // parent ListView / PageView drags still work normally.
    return FeedPinchZoom(
      child: GestureDetector(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: CachedNetworkImage(
          imageUrl: item.mediaUrl,
          fit: fit,
          cacheManager: AppImageCacheManager.instance,
          fadeInDuration: const Duration(milliseconds: 150),
          placeholder: (context, url) => Container(color: colors.surfaceAlt),
          errorWidget: (context, url, error) => Container(
            color: colors.surfaceAlt,
            child: Icon(
              Icons.broken_image_outlined,
              color: colors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }

  /// Compute clamped aspect ratio for a media post. Instagram-style
  /// clamp range: between 4:5 (portrait) and 1.91:1 (landscape). The
  /// frame stays a single fixed shape per post — varying it per swipe
  /// would re-flow every card below it as the user paged through.
  ///
  /// Single-image posts: use the image's own aspect (clamped). Frame
  /// matches the image, no letterboxing; renders BoxFit.cover.
  ///
  /// Uniform-aspect carousels (all images roughly the same shape —
  /// the common case, e.g. N iPhone portraits): behave like the
  /// single-image case. Frame = clamped aspect, BoxFit.cover, no
  /// letterbox. Without this branch, an all-3:4 carousel would clamp
  /// its frame to 4:5 and render every image with tiny black bars
  /// top/bottom — visually distracting for uniform content.
  ///
  /// Mixed-aspect carousels: use the SMALLEST aspect (= most portrait
  /// = tallest frame) so the tallest image fits fully. Shorter images
  /// letterbox into the frame via BoxFit.contain over a black backdrop
  /// — no image gets cropped, at the cost of visible black bars on
  /// non-matching items. See [_isCarouselUniform] for the threshold.
  ///
  /// Videos and dimension-less media (posts created before build 21,
  /// when width/height tracking landed) are skipped in the calculation;
  /// if the carousel has nothing measurable we default to 4:5.
  double _feedAspectRatio(List<PostMedia> media) {
    if (media.isEmpty) return 4 / 5;

    if (media.length == 1) {
      final m = media.first;
      if (m.mediaType == 'video') return 4 / 5;
      if (m.width != null && m.height != null && m.height! > 0) {
        return (m.width! / m.height!).clamp(4 / 5, 1.91);
      }
      return 4 / 5;
    }

    // Carousel
    double? minAspect;
    for (final m in media) {
      if (m.mediaType == 'video') continue;
      if (m.width == null || m.height == null || m.height! <= 0) continue;
      final a = m.width! / m.height!;
      if (minAspect == null || a < minAspect) minAspect = a;
    }
    if (minAspect == null) return 4 / 5;
    return minAspect.clamp(4 / 5, 1.91);
  }

  /// Pick the BoxFit for a single carousel item, given the frame aspect.
  ///
  /// If the item's own aspect is within ~10% of the frame's, the crop
  /// from BoxFit.cover is small enough to be visually invisible — render
  /// clean, no bars. Outside that range the crop would be heavy enough
  /// to be ugly, so letterbox via BoxFit.contain over black to preserve
  /// the image's full content.
  ///
  /// This per-item decision replaces the earlier all-or-nothing
  /// "uniform vs mixed" logic, which letterboxed every item in a
  /// mixed-aspect carousel — including portraits at 3:4 sitting in a
  /// 4:5-clamped frame, where the mismatch was only ~6% but bars were
  /// still drawn. Per-item fit cleans those up while still preserving
  /// the full image of a genuinely off-aspect item (e.g. a landscape
  /// in an otherwise-portrait carousel).
  BoxFit _carouselItemFit(PostMedia item, double frameAspect) {
    if (item.mediaType == 'video') return BoxFit.cover;
    if (item.width == null || item.height == null || item.height! <= 0) {
      return BoxFit.cover;
    }
    final itemAspect = item.width! / item.height!;
    final ratio = (itemAspect - frameAspect).abs() / frameAspect;
    return ratio < 0.10 ? BoxFit.cover : BoxFit.contain;
  }

  Widget _buildMedia(AppColorTokens colors) {
    final media = widget.post.media;
    const radius = BorderRadius.all(Radius.circular(12));

    // Double-tap-to-like is only enabled in feed contexts where the
    // parent wires `onLike`. On surfaces where like isn't surfaced
    // (e.g. post detail without a like button), double-tap stays a
    // no-op so we don't interfere with future double-tap-to-zoom.
    final doubleTap = widget.onLike != null ? _onDoubleTapLike : null;

    if (media.length == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: AspectRatio(
          aspectRatio: _feedAspectRatio(media),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildMediaItem(
                  media[0],
                  colors,
                  onTap: widget.onTap,
                  onDoubleTap: doubleTap,
                ),
                if (doubleTap != null)
                  Center(child: IgnorePointer(child: _buildHeartOverlay())),
              ],
            ),
          ),
        ),
      );
    }

    // Carousel. Frame shape is computed by _feedAspectRatio (smallest
    // aspect among the images, clamped). Each item's BoxFit is decided
    // per item: items close to the frame aspect render BoxFit.cover
    // (the small crop is invisible), items far from it render
    // BoxFit.contain over a black backdrop (the big crop would be ugly,
    // so letterbox to preserve the full image).
    final frameAspect = _feedAspectRatio(media);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AspectRatio(
            aspectRatio: frameAspect,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PageView.builder(
                    itemCount: media.length,
                    onPageChanged: (index) =>
                        setState(() => _currentPage = index),
                    itemBuilder: (context, index) {
                      final fit = _carouselItemFit(media[index], frameAspect);
                      final itemWidget = _buildMediaItem(
                        media[index],
                        colors,
                        onTap: widget.onTap,
                        onDoubleTap: doubleTap,
                        fit: fit,
                      );
                      // Only the letterbox path needs a black backdrop;
                      // BoxFit.cover already fills the frame.
                      return fit == BoxFit.contain
                          ? Container(color: Colors.black, child: itemWidget)
                          : itemWidget;
                    },
                  ),
                  if (doubleTap != null)
                    Center(child: IgnorePointer(child: _buildHeartOverlay())),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(media.length, (index) {
            return Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: index == _currentPage
                    ? colors.textPrimary
                    : colors.textTertiary.withValues(alpha: 0.3),
              ),
            );
          }),
        ),
      ],
    );
  }

  void _showActionSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Share is always present in the menu (own posts only —
            // the menu itself only opens on own posts). Was an action-
            // row button until 1.2; moved here to free up action-row
            // space for the new reactions strip and to keep the share
            // affordance restricted to the post's author.
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Share post'),
              onTap: () {
                Navigator.pop(ctx);
                PostShareUtil.share(
                  context,
                  widget.post,
                  mediaIndex: _currentPage,
                );
              },
            ),
            if (widget.onEditCaption != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit caption'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showEditCaptionDialog(context);
                },
              ),
            if (widget.onDelete != null)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red.shade400),
                title: Text('Delete post',
                    style: TextStyle(color: Colors.red.shade400)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showDeleteConfirmation(context);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showEditCaptionDialog(BuildContext context) {
    final captionController =
        TextEditingController(text: widget.post.caption ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit caption'),
        content: TextField(
          controller: captionController,
          maxLines: 5,
          minLines: 2,
          maxLength: AppLimits.maxCaptionLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Write a caption...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onEditCaption?.call(captionController.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete post?'),
        content: const Text(
            'This will permanently delete this post and all its media.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDelete?.call();
            },
            child: Text(
              'Delete',
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
  }

  static String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    if (diff.inDays < 365) return '${(diff.inDays / 7).floor()}w';
    return '${(diff.inDays / 365).floor()}y';
  }
}

/// Compact tappable icon (+ optional count) used in the action row beneath
/// a post's media. Uniform padding keeps the heart, comment and share icons
/// vertically aligned regardless of whether the heart shows a count.
///
/// Material icon glyphs have different optical centers inside their 24×24
/// box — the iOS share glyph in particular sits visually low because the
/// box-with-arrow puts most of its visual mass in the lower half. The
/// optional [iconOffsetY] nudges a single icon up or down without affecting
/// the surrounding tap target so the row reads as horizontally balanced.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? label;
  final double iconOffsetY;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.onLongPress,
    this.label,
    this.iconOffsetY = 0,
  });

  @override
  Widget build(BuildContext context) {
    final iconWidget = iconOffsetY == 0
        ? Icon(icon, size: 24, color: color)
        : Transform.translate(
            offset: Offset(0, iconOffsetY),
            child: Icon(icon, size: 24, color: color),
          );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            iconWidget,
            if (label != null) ...[
              const SizedBox(width: 6),
              Text(
                label!,
                style: TextStyle(
                  fontSize: 13,
                  color: color,
                  height: 1.0,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "+" emoji button at the right edge of the reactions strip. Pinned
/// outside the strip's horizontal scroll so it's always visible —
/// users never have to scroll the strip to find the reaction entry
/// point. Tap opens the system emoji picker.
class _AddReactionButton extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;

  const _AddReactionButton({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Bare icon — no border. Earlier rounded-pill outline read as
    // visual noise next to the now-borderless reaction chips. The
    // icon glyph alone is recognizable and the InkWell ripple
    // confirms tappability when needed.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          Icons.add_reaction_outlined,
          size: 18,
          color: color,
        ),
      ),
    );
  }
}

/// Tappable like-count pill that sits next to the heart icon. Tap
/// opens the [LikesSheet] (the same sheet the heart's long-press
/// shows), making the formerly-invisible long-press affordance
/// discoverable for users who don't think to long-press a heart.
///
/// Visual: bare number with the same color/weight as the old inline
/// label, but rendered as its own InkWell so the ripple confirms it's
/// a separate tap target. Left padding intentionally smaller than the
/// _ActionButton's so the count visually hugs the heart instead of
/// reading as a third standalone button.
class _LikeCountChip extends StatelessWidget {
  final int count;
  final Color color;
  final VoidCallback onTap;

  const _LikeCountChip({
    required this.count,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 8, 10, 8),
        child: Text(
          '$count',
          style: TextStyle(
            fontSize: 13,
            color: color,
            height: 1.0,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Shows the first frame of a video with a play icon overlay.
/// Used in feed/grid contexts where tapping navigates to post detail.
class _VideoStaticThumbnail extends StatefulWidget {
  final String url;
  final AppColorTokens colors;

  const _VideoStaticThumbnail({required this.url, required this.colors});

  @override
  State<_VideoStaticThumbnail> createState() => _VideoStaticThumbnailState();
}

class _VideoStaticThumbnailState extends State<_VideoStaticThumbnail> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Container(
        color: widget.colors.surfaceAlt,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller.value.size.width,
              height: _controller.value.size.height,
              child: VideoPlayer(_controller),
            ),
          ),
        ),
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black54,
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 36,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

/// Displays a video with a play button overlay. Tap to play/pause.
/// No autoplay — video starts paused with a centered play icon.
class _VideoThumbnail extends StatefulWidget {
  final String url;
  final AppColorTokens colors;

  const _VideoThumbnail({required this.url, required this.colors});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayback() {
    if (!_initialized) return;
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Container(
        color: widget.colors.surfaceAlt,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return GestureDetector(
      onTap: _togglePlayback,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller.value.size.width,
                height: _controller.value.size.height,
                child: VideoPlayer(_controller),
              ),
            ),
          ),
          if (!_controller.value.isPlaying)
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black54,
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 36,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}
