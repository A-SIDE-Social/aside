import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../core/config/constants.dart';
import '../../core/network/upload_watchdog.dart';
import '../../providers/providers.dart';

/// Shows the story media picker sheet over the current screen.
/// Calls [onCreated] if a story was successfully created.
void showStoryPicker(BuildContext context, {VoidCallback? onCreated}) {
  final picker = ImagePicker();

  void openPreview(BuildContext outerContext, String path, bool isVideo) {
    Navigator.of(outerContext, rootNavigator: true)
        .push<bool>(
      MaterialPageRoute(
        builder: (_) => CreateStoryScreen(
          mediaPath: path,
          isVideo: isVideo,
        ),
      ),
    )
        .then((success) {
      if (success == true) onCreated?.call();
    });
  }

  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Take photo'),
            onTap: () async {
              Navigator.pop(ctx);
              final picked = await picker.pickImage(source: ImageSource.camera);
              if (picked != null && context.mounted) {
                openPreview(context, picked.path, false);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('Record video'),
            onTap: () async {
              Navigator.pop(ctx);
              final picked = await picker.pickVideo(
                source: ImageSource.camera,
                maxDuration:
                    const Duration(seconds: AppLimits.maxVideoStorySeconds),
              );
              if (picked != null && context.mounted) {
                openPreview(context, picked.path, true);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photo from library'),
            onTap: () async {
              Navigator.pop(ctx);
              final picked =
                  await picker.pickImage(source: ImageSource.gallery);
              if (picked != null && context.mounted) {
                openPreview(context, picked.path, false);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: const Text('Video from library'),
            onTap: () async {
              Navigator.pop(ctx);
              final picked =
                  await picker.pickVideo(source: ImageSource.gallery);
              if (picked != null && context.mounted) {
                openPreview(context, picked.path, true);
              }
            },
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
}

class CreateStoryScreen extends ConsumerStatefulWidget {
  final String mediaPath;
  final bool isVideo;

  const CreateStoryScreen({
    super.key,
    required this.mediaPath,
    required this.isVideo,
  });

  @override
  ConsumerState<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

class _CreateStoryScreenState extends ConsumerState<CreateStoryScreen> {
  bool _isUploading = false;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _videoController = VideoPlayerController.file(File(widget.mediaPath))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {});
            _videoController!.setLooping(true);
            _videoController!.play();
          }
        });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    if (_isUploading) return;

    setState(() => _isUploading = true);

    final api = ref.read(apiServiceProvider);
    final contentType = widget.isVideo ? 'video/mp4' : 'image/jpeg';
    final cancelToken = CancelToken();
    final watchdog = UploadWatchdog(cancelToken: cancelToken);

    try {
      // 1. Get upload URL
      final uploadData = await api.getStoryUploadUrl(contentType);
      final uploadUrl = uploadData['upload_url'] as String;
      final key = uploadData['key'] as String;

      // 2. Upload the file with stall watchdog
      final bytes = await File(widget.mediaPath).readAsBytes();
      await api.uploadBytes(
        uploadUrl,
        bytes,
        contentType,
        cancelToken: cancelToken,
        onSendProgress: (_, __) => watchdog.noteProgress(),
      );

      // 3. Create the story
      final mediaType = widget.isVideo ? 'video' : 'photo';
      await api.createStory(key, mediaType);

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final stalled = isUploadStallOrTimeout(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            stalled ? 'Upload timed out' : 'Failed to share story',
          ),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: _share,
          ),
        ),
      );
    } finally {
      watchdog.stop();
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Preview
          if (widget.isVideo && _videoController != null)
            _videoController!.value.isInitialized
                ? Center(
                    child: AspectRatio(
                      aspectRatio: _videoController!.value.aspectRatio,
                      child: VideoPlayer(_videoController!),
                    ),
                  )
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white54),
                  )
          else
            Image.file(
              File(widget.mediaPath),
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
            ),

          // Top bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // Share button
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 20,
            left: 20,
            right: 20,
            child: ElevatedButton(
              onPressed: _isUploading ? null : _share,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: _isUploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Text(
                      'Share to Story',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
