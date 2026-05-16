import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/cache/image_cache_manager.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.storyGroups,
    this.initialGroupIndex = 0,
    this.initialStoryIndex = 0,
    this.currentUserId,
    this.onChanged,
  });

  final List<StoryGroup> storyGroups;
  final int initialGroupIndex;
  final int initialStoryIndex;
  final String? currentUserId;
  final VoidCallback? onChanged;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  late List<StoryGroup> _storyGroups;
  late int _currentGroupIndex;
  late int _currentStoryIndex;
  late AnimationController _progressController;
  VideoPlayerController? _videoController;
  bool _didChange = false;

  static const _photoDuration = Duration(seconds: 5);

  StoryGroup get _currentGroup => _storyGroups[_currentGroupIndex];
  Story get _currentStory => _currentGroup.stories[_currentStoryIndex];
  bool get _isOwnStory => _currentGroup.userId == widget.currentUserId;

  @override
  void initState() {
    super.initState();
    // Make a mutable copy
    _storyGroups = widget.storyGroups
        .map((g) => StoryGroup(
              userId: g.userId,
              displayName: g.displayName,
              avatarUrl: g.avatarUrl,
              stories: List.of(g.stories),
            ))
        .toList();
    _currentGroupIndex = widget.initialGroupIndex;
    _currentStoryIndex = widget.initialStoryIndex;
    _progressController = AnimationController(
      vsync: this,
      duration: _photoDuration,
    )..addStatusListener(_onProgressComplete);
    _loadStory();
  }

  @override
  void dispose() {
    _progressController.dispose();
    _videoController?.removeListener(_onVideoProgress);
    _videoController?.dispose();
    if (_didChange) widget.onChanged?.call();
    super.dispose();
  }

  void _loadStory() {
    final story = _currentStory;
    _videoController?.removeListener(_onVideoProgress);
    _videoController?.dispose();
    _videoController = null;

    if (story.mediaType == 'video') {
      _progressController.reset();
      final vc = VideoPlayerController.networkUrl(Uri.parse(story.mediaUrl));
      _videoController = vc;
      vc.initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        _progressController.duration = vc.value.duration;
        vc.addListener(_onVideoProgress);
        vc.play();
        // Don't use _progressController.forward() — we'll drive it from video position
      });
    } else {
      _progressController.duration = _photoDuration;
      _progressController
        ..reset()
        ..forward();
    }
  }

  void _onVideoProgress() {
    final vc = _videoController;
    if (vc == null || !vc.value.isInitialized) return;

    final duration = vc.value.duration;
    final position = vc.value.position;

    if (duration.inMilliseconds > 0) {
      final progress = position.inMilliseconds / duration.inMilliseconds;
      _progressController.value = progress.clamp(0.0, 1.0);
    }

    // Video finished playing
    if (position >= duration && duration.inMilliseconds > 0) {
      vc.removeListener(_onVideoProgress);
      _goNext();
    }
  }

  void _onProgressComplete(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      // For videos, _onVideoProgress handles advancement
      if (_currentStory.mediaType != 'video') {
        _goNext();
      }
    }
  }

  void _goNext() {
    if (_currentStoryIndex < _currentGroup.stories.length - 1) {
      setState(() => _currentStoryIndex++);
      _loadStory();
    } else if (_currentGroupIndex < _storyGroups.length - 1) {
      setState(() {
        _currentGroupIndex++;
        _currentStoryIndex = 0;
      });
      _loadStory();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _goPrevious() {
    if (_currentStoryIndex > 0) {
      setState(() => _currentStoryIndex--);
      _loadStory();
    } else if (_currentGroupIndex > 0) {
      setState(() {
        _currentGroupIndex--;
        _currentStoryIndex = _currentGroup.stories.length - 1;
      });
      _loadStory();
    } else {
      _loadStory();
    }
  }

  void _onTap(TapUpDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    if (details.globalPosition.dx < screenWidth / 3) {
      _goPrevious();
    } else {
      _goNext();
    }
  }

  Future<void> _deleteCurrentStory() async {
    final story = _currentStory;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete story?'),
        content: const Text('This story will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    _progressController.stop();

    try {
      final api = ref.read(apiServiceProvider);
      await api.deleteStory(story.id);
      _didChange = true;

      // Remove from local list
      final group = _storyGroups[_currentGroupIndex];
      group.stories.removeAt(_currentStoryIndex);

      if (group.stories.isEmpty) {
        _storyGroups.removeAt(_currentGroupIndex);
        if (_storyGroups.isEmpty) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
        if (_currentGroupIndex >= _storyGroups.length) {
          _currentGroupIndex = _storyGroups.length - 1;
        }
        _currentStoryIndex = 0;
      } else if (_currentStoryIndex >= group.stories.length) {
        _currentStoryIndex = group.stories.length - 1;
      }

      if (mounted) {
        setState(() {});
        _loadStory();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
        _progressController.forward();
      }
    }
  }

  String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final story = _currentStory;
    final group = _currentGroup;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: _onTap,
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null &&
              details.primaryVelocity! > 300) {
            Navigator.of(context).pop();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Story media
            _StoryMedia(
              story: story,
              videoController: _videoController,
            ),

            // Gradient overlay
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 120,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xAA000000),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Progress bars + user info
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 12,
              right: 12,
              child: Column(
                children: [
                  // Progress indicators
                  Row(
                    children: List.generate(
                      group.stories.length,
                      (index) => Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: index < group.stories.length - 1 ? 3 : 0,
                          ),
                          child: _ProgressBar(
                            isCurrent: index == _currentStoryIndex,
                            isComplete: index < _currentStoryIndex,
                            controller: _progressController,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // User info bar
                  Row(
                    children: [
                      Avatar(
                        imageUrl: group.avatarUrl,
                        displayName: group.displayName,
                        size: 32,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        group.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _timeAgo(story.createdAt),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      if (_isOwnStory)
                        IconButton(
                          onPressed: _deleteCurrentStory,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.isCurrent,
    required this.isComplete,
    required this.controller,
  });

  final bool isCurrent;
  final bool isComplete;
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 2,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(1),
        color: Colors.white.withValues(alpha: 0.3),
      ),
      child: isCurrent
          ? AnimatedBuilder(
              animation: controller,
              builder: (context, child) {
                return FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: controller.value,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(1),
                      color: Colors.white,
                    ),
                  ),
                );
              },
            )
          : isComplete
              ? Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    color: Colors.white,
                  ),
                )
              : null,
    );
  }
}

class _StoryMedia extends StatelessWidget {
  const _StoryMedia({
    required this.story,
    this.videoController,
  });

  final Story story;
  final VideoPlayerController? videoController;

  @override
  Widget build(BuildContext context) {
    if (story.mediaType == 'video' && videoController != null) {
      if (videoController!.value.isInitialized) {
        return Center(
          child: AspectRatio(
            aspectRatio: videoController!.value.aspectRatio,
            child: VideoPlayer(videoController!),
          ),
        );
      }
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white,
          ),
        ),
      );
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cachePx = (MediaQuery.sizeOf(context).width * dpr).round();
    return CachedNetworkImage(
      imageUrl: story.mediaUrl,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      cacheManager: AppImageCacheManager.instance,
      memCacheWidth: cachePx,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (context, url) => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white,
          ),
        ),
      ),
      errorWidget: (context, url, error) => const Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 48,
        ),
      ),
    );
  }
}
