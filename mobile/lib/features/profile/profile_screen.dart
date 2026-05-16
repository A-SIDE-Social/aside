import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../core/cache/image_cache_manager.dart';
import '../../core/config/app_colors.dart';
import '../../core/media/image_compression.dart';
import '../../core/network/upload_watchdog.dart';
import '../../widgets/widgets.dart';
import '../../providers/providers.dart';
import '../../models/models.dart';
import 'user_connections_sheet.dart';

/// Provider that fetches another user's profile by ID.
///
/// Not auto-disposed: returning to a previously viewed profile feels instant.
final _userProfileProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, userId) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getUser(userId);
  return data as Map<String, dynamic>;
});

class ProfileScreen extends ConsumerStatefulWidget {
  final String? userId;

  const ProfileScreen({super.key, this.userId});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    if (_isOwnProfile) {
      _tabController = TabController(length: 2, vsync: this);
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  bool get _isOwnProfile => widget.userId == null;

  String get _targetUserId {
    if (_isOwnProfile) {
      return ref.read(authProvider).user?.id ?? '';
    }
    return widget.userId!;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final currentUser = ref.watch(authProvider).user;

    if (_isOwnProfile) {
      return _buildOwnProfile(context, currentUser, colors, theme);
    }

    // If viewing own profile via ID, redirect to own profile view
    if (widget.userId == currentUser?.id) {
      return _buildOwnProfile(context, currentUser, colors, theme);
    }

    final profileAsync = ref.watch(_userProfileProvider(_targetUserId));

    return profileAsync.when(
      data: (profileData) {
        final user = User.fromJson(profileData);
        final isMutual = profileData['is_mutual_follow'] as bool? ?? false;
        final isFollowing = profileData['is_following'] as bool? ?? false;
        final isFollowedBy = profileData['is_followed_by'] as bool? ?? false;
        final mutualCount = profileData['mutual_follow_count'] as int? ?? 0;

        return Scaffold(
          appBar: AppBar(
            title: Text(user.displayName),
            actions: [
              if (isMutual)
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  onSelected: (value) {
                    if (value == 'disconnect') {
                      _confirmDisconnect(user);
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'disconnect',
                      child: Row(
                        children: [
                          Icon(Icons.person_remove_outlined,
                              size: 20, color: Colors.red),
                          SizedBox(width: 12),
                          Text('Disconnect',
                              style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                )
              else if (isFollowing && !isMutual)
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  onSelected: (value) {
                    if (value == 'cancel') {
                      _cancelRequest(user);
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'cancel',
                      child: Row(
                        children: [
                          Icon(Icons.close_rounded, size: 20),
                          SizedBox(width: 12),
                          Text('Cancel Request'),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
          body: _buildProfileBody(
            context: context,
            user: user,
            isOwnProfile: false,
            isMutual: isMutual,
            isFollowing: isFollowing,
            isFollowedBy: isFollowedBy,
            mutualCount: mutualCount,
            colors: colors,
            theme: theme,
          ),
        );
      },
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const LoadingIndicator(),
      ),
      error: (error, _) => Scaffold(
        appBar: AppBar(),
        body: ErrorView(
          message: error.toString(),
          onRetry: () => ref.invalidate(_userProfileProvider(_targetUserId)),
        ),
      ),
    );
  }

  Widget _buildOwnProfile(
    BuildContext context,
    User? user,
    AppColorTokens colors,
    ThemeData theme,
  ) {
    if (user == null) {
      return const Scaffold(body: LoadingIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(user.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 28),
            onPressed: () => context.push('/post/new'),
          ),
        ],
      ),
      body: _buildProfileBody(
        context: context,
        user: user,
        isOwnProfile: true,
        isMutual: false,
        isFollowing: false,
        isFollowedBy: false,
        mutualCount: 0,
        colors: colors,
        theme: theme,
      ),
    );
  }

  Widget _buildProfileBody({
    required BuildContext context,
    required User user,
    required bool isOwnProfile,
    required bool isMutual,
    required bool isFollowing,
    required bool isFollowedBy,
    required int mutualCount,
    required AppColorTokens colors,
    required ThemeData theme,
  }) {
    final postsAsync = ref.watch(userPostsProvider(user.id));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final gridCachePx = ((MediaQuery.sizeOf(context).width / 3) * dpr).round();

    return RefreshIndicator(
      onRefresh: () async {
        if (!isOwnProfile) {
          ref.invalidate(_userProfileProvider(user.id));
        }
        ref.invalidate(userPostsProvider(user.id));
      },
      child: CustomScrollView(
        slivers: [
          // Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: isOwnProfile ? () => _pickAvatar(user) : null,
                    child: Stack(
                      children: [
                        Avatar(
                          imageUrl: user.avatarUrl,
                          displayName: user.displayName,
                          size: 80,
                        ),
                        if (isOwnProfile)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.accent,
                                border: Border.all(
                                  color: colors.surface,
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                Icons.camera_alt,
                                size: 14,
                                color: colors.surface,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (user.bio != null && user.bio!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      user.bio!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (!isOwnProfile) ...[
                    const SizedBox(height: 16),
                    if (isMutual)
                      // Both buttons share the same OutlinedButton style
                      // so they read as a paired affordance — neither is
                      // visually louder than the other. Subtle (w500)
                      // text, not bold; clear border so they still read
                      // as buttons. Friends label includes the word
                      // "Friends" + the count so it's self-describing
                      // without an icon-only mystery chip.
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: 36,
                            child: OutlinedButton.icon(
                              onPressed: () => _openConversation(user),
                              icon: const Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  size: 16),
                              label: const Text('Message'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 36),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                textStyle: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 36,
                            child: OutlinedButton.icon(
                              onPressed: () => showUserConnectionsSheet(
                                context,
                                user.id,
                                user.displayName,
                              ),
                              icon: const Icon(Icons.people_outline_rounded,
                                  size: 16),
                              label: Text('Friends $mutualCount'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 36),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                textStyle: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (isFollowedBy && !isFollowing)
                      // They requested us — show Accept button
                      SizedBox(
                        width: 200,
                        height: 40,
                        child: ElevatedButton.icon(
                          onPressed: () => _toggleFollow(user.id, false),
                          icon: const Icon(Icons.person_add_alt_1_rounded,
                              size: 18),
                          label: const Text('Accept'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                          ),
                        ),
                      )
                    else if (isFollowing && !isMutual)
                      // We requested them — show Requested
                      SizedBox(
                        width: 200,
                        height: 40,
                        child: OutlinedButton(
                          onPressed: () => _cancelRequest(user),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                          ),
                          child: const Text('Requested'),
                        ),
                      )
                    else
                      // Not connected at all — show Connect
                      SizedBox(
                        width: 200,
                        height: 40,
                        child: ElevatedButton.icon(
                          onPressed: () => _toggleFollow(user.id, false),
                          icon: const Icon(Icons.person_add_alt_1_rounded,
                              size: 18),
                          label: const Text('Connect'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),

          if (isOwnProfile && _tabController != null)
            SliverToBoxAdapter(
              child: Column(
                children: [
                  TabBar(
                    controller: _tabController,
                    labelColor: colors.textPrimary,
                    unselectedLabelColor: colors.textTertiary,
                    indicatorColor: colors.textPrimary,
                    tabs: const [
                      Tab(icon: Icon(Icons.grid_on_rounded, size: 22)),
                      Tab(icon: Icon(Icons.timer_outlined, size: 22)),
                    ],
                  ),
                ],
              ),
            )
          else
            SliverToBoxAdapter(
              child: Divider(color: colors.borderSubtle),
            ),

          // Posts grid
          if (!isOwnProfile && !isMutual)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 48,
                        color: colors.textTertiary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Content is private',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Connect to see their posts and stories.',
                        style: theme.textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            postsAsync.when(
              data: (posts) {
                // For own profile with tabs, split into active and hidden
                final List<Post> activePosts;
                final List<Post> hiddenPosts;
                if (isOwnProfile && _tabController != null) {
                  final now = DateTime.now();
                  activePosts = posts
                      .where((p) =>
                          p.expiresAt == null || p.expiresAt!.isAfter(now))
                      .toList();
                  hiddenPosts = posts
                      .where((p) =>
                          p.expiresAt != null && p.expiresAt!.isBefore(now))
                      .toList();
                } else {
                  activePosts = posts;
                  hiddenPosts = [];
                }

                if (isOwnProfile && _tabController != null) {
                  return _buildTabbedGrid(
                    activePosts: activePosts,
                    hiddenPosts: hiddenPosts,
                    colors: colors,
                    theme: theme,
                    gridCachePx: gridCachePx,
                  );
                }

                if (activePosts.isEmpty) {
                  return const SliverFillRemaining(
                    child: EmptyState(
                      icon: Icons.camera_alt_outlined,
                      title: 'No posts yet',
                    ),
                  );
                }

                return _buildPostGrid(activePosts, colors, theme, gridCachePx);
              },
              loading: () => const SliverFillRemaining(
                child: LoadingIndicator(),
              ),
              error: (error, _) => SliverFillRemaining(
                child: ErrorView(
                  message: error.toString(),
                  onRetry: () => ref.invalidate(userPostsProvider(user.id)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPostGrid(
    List<Post> posts,
    AppColorTokens colors,
    ThemeData theme,
    int gridCachePx, {
    bool showExpiredOverlay = false,
  }) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 1,
        mainAxisSpacing: 1,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final post = posts[index];
          return GestureDetector(
            onTap: () => context.push('/post/${post.id}'),
            child: post.media.isNotEmpty
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      if (post.media.first.mediaType == 'video')
                        _VideoGridThumbnail(
                          url: post.media.first.mediaUrl,
                          colors: colors,
                        )
                      else
                        CachedNetworkImage(
                          imageUrl: post.media.first.mediaUrl,
                          fit: BoxFit.cover,
                          cacheManager: AppImageCacheManager.instance,
                          memCacheWidth: gridCachePx,
                          fadeInDuration: const Duration(milliseconds: 150),
                          placeholder: (context, url) =>
                              Container(color: colors.surfaceAlt),
                          errorWidget: (context, url, error) => Container(
                            color: colors.surfaceAlt,
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: colors.textTertiary,
                            ),
                          ),
                        ),
                      if (post.media.first.mediaType == 'video')
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 20,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      if (showExpiredOverlay)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.4),
                            child: const Center(
                              child: Icon(
                                Icons.timer_off_outlined,
                                color: Colors.white70,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                    ],
                  )
                : Stack(
                    children: [
                      Container(
                        color: colors.surfaceAlt,
                        padding: const EdgeInsets.all(8),
                        alignment: Alignment.center,
                        child: Text(
                          post.caption ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            height: 1.3,
                            color: colors.textPrimary,
                          ),
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (showExpiredOverlay)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.4),
                            child: const Center(
                              child: Icon(
                                Icons.timer_off_outlined,
                                color: Colors.white70,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          );
        },
        childCount: posts.length,
      ),
    );
  }

  Widget _buildTabbedGrid({
    required List<Post> activePosts,
    required List<Post> hiddenPosts,
    required AppColorTokens colors,
    required ThemeData theme,
    required int gridCachePx,
  }) {
    return ListenableBuilder(
      listenable: _tabController!,
      builder: (context, _) {
        final showHidden = _tabController!.index == 1;
        final displayPosts = showHidden ? hiddenPosts : activePosts;

        if (displayPosts.isEmpty) {
          return SliverFillRemaining(
            child: EmptyState(
              icon: showHidden
                  ? Icons.timer_off_outlined
                  : Icons.camera_alt_outlined,
              title: showHidden ? 'No hidden posts' : 'No posts yet',
            ),
          );
        }

        return _buildPostGrid(
          displayPosts,
          colors,
          theme,
          gridCachePx,
          showExpiredOverlay: showHidden,
        );
      },
    );
  }

  void _cancelRequest(User user) {
    _toggleFollow(user.id, true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection request cancelled')),
      );
    }
  }

  void _confirmDisconnect(User user) {
    final colors = AppColors.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.border, width: 0.5),
        ),
        title: const Text('Disconnect?'),
        content: Text(
          'Remove ${user.displayName}? You will no longer see each other\'s posts or stories.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _toggleFollow(user.id, true);
            },
            child: Text(
              'Disconnect',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openConversation(User user) async {
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.createConversation(user.id);
      final conversation = Conversation.fromJson(data as Map<String, dynamic>);
      if (mounted) {
        context.push('/conversations/${conversation.id}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open conversation: $e')),
        );
      }
    }
  }

  Future<void> _pickAvatar(User user) async {
    final picker = ImagePicker();

    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (user.avatarUrl != null)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red.shade400),
                title: Text('Remove photo',
                    style: TextStyle(color: Colors.red.shade400)),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    if (result == 'remove') {
      try {
        final api = ref.read(apiServiceProvider);
        final updatedData = await api.updateMe(avatarUrl: '');
        final updatedUser = User.fromJson(updatedData as Map<String, dynamic>);
        ref.read(authProvider.notifier).setUser(updatedUser);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile photo removed')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to remove photo: $e')),
          );
        }
      }
      return;
    }

    final source =
        result == 'camera' ? ImageSource.camera : ImageSource.gallery;
    if (!mounted) return;

    final picked = await picker.pickImage(
      source: source,
      preferredCameraDevice: CameraDevice.front,
    );
    if (picked == null || !mounted) return;

    final api = ref.read(apiServiceProvider);
    final cancelToken = CancelToken();
    final watchdog = UploadWatchdog(cancelToken: cancelToken);

    try {
      // 1. Get upload URL
      final uploadData = await api.getAvatarUploadUrl('image/jpeg');
      final uploadUrl = uploadData['upload_url'] as String;
      final key = uploadData['key'] as String;

      // 2. Compress (strip EXIF, resize, JPEG Q80) then upload.
      // Avatars only ever render at ~160px × 3x dpr, so 512 is plenty.
      final compressed = await compressImageForUpload(
        picked.path,
        maxDimension: 512,
        quality: 80,
      );
      await api.uploadBytes(
        uploadUrl,
        compressed.bytes,
        'image/jpeg',
        cancelToken: cancelToken,
        onSendProgress: (_, __) => watchdog.noteProgress(),
      );

      // 3. Update profile with the key
      final updatedData = await api.updateMe(avatarUrl: key);
      final updatedUser = User.fromJson(updatedData as Map<String, dynamic>);

      // 4. Update local auth state
      ref.read(authProvider.notifier).setUser(updatedUser);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile photo updated')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final stalled = isUploadStallOrTimeout(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            stalled ? 'Upload timed out' : 'Failed to update photo',
          ),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _pickAvatar(user),
          ),
        ),
      );
    } finally {
      watchdog.stop();
    }
  }

  Future<void> _toggleFollow(String userId, bool isFollowing) async {
    try {
      final api = ref.read(apiServiceProvider);
      if (isFollowing) {
        await api.unfollow(userId);
      } else {
        await api.follow(userId);
      }
      ref.invalidate(_userProfileProvider(_targetUserId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }
}

/// Shows the first frame of a video, center-cropped to fill a square grid cell.
class _VideoGridThumbnail extends StatefulWidget {
  final String url;
  final AppColorTokens colors;

  const _VideoGridThumbnail({required this.url, required this.colors});

  @override
  State<_VideoGridThumbnail> createState() => _VideoGridThumbnailState();
}

class _VideoGridThumbnailState extends State<_VideoGridThumbnail> {
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
      return Container(color: widget.colors.surfaceAlt);
    }
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _controller.value.size.width,
          height: _controller.value.size.height,
          child: VideoPlayer(_controller),
        ),
      ),
    );
  }
}
