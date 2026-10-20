import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/constants.dart';
import '../../core/media/film_filters.dart';
import '../../core/media/media_transform.dart';
import '../../core/media/image_compression.dart';
import '../../core/media/video_processing.dart';
import '../../core/network/upload_watchdog.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';
import '../../core/services/voice_caption_service.dart';
import '../../widgets/voice_caption_editor.dart';
import 'media_edit_sheet.dart';

/// Thrown when an upload has made no progress for longer than the stall
/// threshold. Treated the same as a Dio timeout by the error handler.
class _UploadStalled implements Exception {
  const _UploadStalled();
}

/// Single in-composer media item. Replaces the old parallel collections
/// (selectedMedia / videoIndices / filtersByIndex / transformsByIndex /
/// completedMedia) so reordering, deleting, editing, and resuming all
/// operate on a single typed list. The stable [id] survives reorders and
/// is used as the [Key] for [ReorderableListView].
class _ComposerMedia {
  _ComposerMedia({
    required this.file,
    required this.isVideo,
    this.filter,
    this.transform,
    this.completed,
  }) : id = '${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  static int _idSeq = 0;

  final String id;
  XFile file;
  final bool isVideo;
  FilmFilter? filter;
  MediaTransform? transform;

  /// Server-side metadata from a successful upload (key, media_type,
  /// width, height, thumbnail_key). Null until uploaded. `position` is
  /// re-derived from current list index at submit time so reordering
  /// after upload still produces correct ordering on the server.
  Map<String, dynamic>? completed;
}

class CreatePostScreen extends ConsumerStatefulWidget {
  const CreatePostScreen({super.key});

  @override
  ConsumerState<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends ConsumerState<CreatePostScreen>
    with WidgetsBindingObserver {
  final _captionController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<_ComposerMedia> _media = [];
  bool _isPosting = false;
  bool _isTextPost = false;
  VoiceRecording? _voiceCaption;
  bool _recordingVoice = false;
  String? _uploadedVoiceCaptionId;
  final Set<String> _temporaryVoicePaths = {};
  bool _hideAfter24h = false;
  final Set<String> _selectedAudienceListIds = {};

  // Upload progress + stall watchdog state
  double _uploadProgress = 0.0; // 0.0–1.0 across all files
  int _uploadingFileIndex = 0;
  int _uploadTotalFiles = 0;
  UploadWatchdog? _watchdog;

  // If the user resumed from a draft, this is its id so we can delete it on
  // successful post.
  String? _resumingDraftId;
  DateTime? _draftCreatedAt;
  Timer? _draftTimer;
  int _draftRevision = 0;
  bool _draftSaved = false;
  bool _allowPop = false;
  bool _closing = false;
  bool _published = false;
  bool _showingPostTypePicker = false;
  String? _draftError;

  static const _maxMedia = AppLimits.maxPhotosPerPost;
  static const _maxCaptionLength = AppLimits.maxCaptionLength;
  static const _maxTextPostLength = AppLimits.maxTextPostLength;
  static const _maxVideoSeconds = AppLimits.maxVideoPostSeconds;

  int get _completedCount => _media.where((m) => m.completed != null).length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _captionController.addListener(_scheduleDraftSave);
    // Only show the post type picker on a fresh Create Post screen. If we
    // have drafts the user may want to resume, skip straight to the banner.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(draftProvider.notifier).ready;
      final legacyCount = await ref.read(legacyDraftCountProvider.future);
      if (!mounted) return;
      final drafts = ref.read(draftProvider);
      if (drafts.isEmpty && legacyCount == 0) {
        _showPostTypePicker();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftTimer?.cancel();
    _watchdog?.stop();
    _captionController.removeListener(_scheduleDraftSave);
    _captionController.dispose();
    super.dispose();
  }

  void _showPostTypePicker() {
    if (_showingPostTypePicker) return;
    setState(() => _showingPostTypePicker = true);
    var didPick = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('Take photo'),
                onTap: () {
                  didPick = true;
                  Navigator.pop(ctx);
                  _pickFromCamera().then((_) {
                    if (_media.isEmpty && mounted) context.pop();
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from library'),
                onTap: () {
                  didPick = true;
                  Navigator.pop(ctx);
                  _pickFromLibrary().then((_) {
                    if (_media.isEmpty && mounted) context.pop();
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: Text('Record video (${_maxVideoSeconds}s)'),
                onTap: () {
                  didPick = true;
                  Navigator.pop(ctx);
                  _recordVideo().then((_) {
                    if (_media.isEmpty && mounted) context.pop();
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library_outlined),
                title: Text('Choose video from library (${_maxVideoSeconds}s)'),
                onTap: () {
                  didPick = true;
                  Navigator.pop(ctx);
                  _pickVideoFromLibrary().then((_) {
                    if (_media.isEmpty && mounted) context.pop();
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.text_fields_outlined),
                title: const Text('Text post'),
                onTap: () {
                  didPick = true;
                  Navigator.pop(ctx);
                  _edit(() => _isTextPost = true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Cancel'),
                onTap: () {
                  didPick = true;
                  Navigator.pop(ctx);
                  context.pop();
                },
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      if (!mounted) return;
      setState(() => _showingPostTypePicker = false);
      if (!didPick && _media.isEmpty && !_isTextPost && mounted) {
        context.pop();
      }
    });
  }

  Future<void> _pickFromLibrary() async {
    final remaining = _maxMedia - _media.length;
    if (remaining <= 0) return;

    final picked = await _imagePicker.pickMultiImage(limit: remaining);
    if (picked.isNotEmpty && mounted) {
      _edit(() {
        for (final x in picked.take(remaining)) {
          _media.add(_ComposerMedia(file: x, isVideo: false));
        }
        _isTextPost = false;
      });
    }
  }

  Future<void> _pickFromCamera() async {
    while (_media.length < _maxMedia) {
      final photo = await _imagePicker.pickImage(source: ImageSource.camera);
      if (photo == null || !mounted) break;
      _edit(() {
        _media.add(_ComposerMedia(file: photo, isVideo: false));
        _isTextPost = false;
      });

      if (_media.length >= _maxMedia) break;

      final takeAnother = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${_media.length}/$_maxMedia photos'),
          content: const Text('Take another photo?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Done'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Take another'),
            ),
          ],
        ),
      );
      if (takeAnother != true) break;
    }
  }

  Future<void> _recordVideo() async {
    final video = await _imagePicker.pickVideo(
      source: ImageSource.camera,
      maxDuration: Duration(seconds: _maxVideoSeconds),
    );
    if (video == null || !mounted) return;

    _edit(() {
      _media.add(_ComposerMedia(file: video, isVideo: true));
      _isTextPost = false;
    });
  }

  Future<void> _pickVideoFromLibrary() async {
    final video = await _imagePicker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: Duration(seconds: _maxVideoSeconds),
    );
    if (video == null || !mounted) return;

    _edit(() {
      _media.add(_ComposerMedia(file: video, isVideo: true));
      _isTextPost = false;
    });
  }

  /// Returns the filter for a specific media index, defaulting to none.
  FilmFilter _filterFor(int index) => _media[index].filter ?? FilmFilters.none;

  /// Returns the crop+straighten transform for a specific media index,
  /// defaulting to identity.
  MediaTransform _transformFor(int index) =>
      _media[index].transform ?? MediaTransform.identity;

  void _showMediaSourcePicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFromCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFromLibrary();
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: Text('Record video (${_maxVideoSeconds}s)'),
              onTap: () {
                Navigator.pop(ctx);
                _recordVideo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: Text('Choose video from library (${_maxVideoSeconds}s)'),
              onTap: () {
                Navigator.pop(ctx);
                _pickVideoFromLibrary();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _removeMedia(int index) {
    _edit(() {
      _media.removeAt(index);
    });
  }

  /// Reorder callback for [ReorderableListView]. Translates the
  /// drag-end indices into a list move. Stable [_ComposerMedia.id] keys
  /// mean filter / transform / completed metadata travel with the item
  /// for free — no parallel-map fixup needed.
  void _reorderMedia(int oldIndex, int newIndex) {
    _edit(() {
      final item = _media.removeAt(oldIndex);
      _media.insert(newIndex, item);
    });
  }

  /// Opens the media editor sheet for a specific image. Filters and
  /// transforms live on the [_ComposerMedia] item; the sheet reads through
  /// getters and writes back through callbacks. All gesture/aspect/page-
  /// index complexity lives in the sheet — see media_edit_sheet.dart.
  void _showFilterOverlay(int initialIndex) {
    final photoMediaIndices = <int>[];
    final photos = <XFile>[];
    for (var i = 0; i < _media.length; i++) {
      if (!_media[i].isVideo) {
        photoMediaIndices.add(i);
        photos.add(_media[i].file);
      }
    }
    if (photoMediaIndices.isEmpty) return;

    showMediaEditSheet(
      context,
      photos: photos,
      photoMediaIndices: photoMediaIndices,
      initialIndex: initialIndex,
      filterFor: _filterFor,
      transformFor: _transformFor,
      onFilterChanged: (idx, f) {
        _edit(() {
          _media[idx].filter = f.isNone ? null : f;
          _media[idx].completed = null;
        });
      },
      onTransformChanged: (idx, t) {
        _edit(() {
          _media[idx].transform = t.isIdentity ? null : t;
          _media[idx].completed = null;
        });
      },
    );
  }

  bool get _canShare {
    if (_recordingVoice ||
        (_voiceCaption != null && !_media.any((item) => !item.isVideo))) {
      return false;
    }
    if (_isPosting) return false;
    if (_isTextPost) return _captionController.text.trim().isNotEmpty;
    return _media.isNotEmpty;
  }

  int _audienceMemberCount(List<GroupWithMembers> lists) {
    final memberIds = <String>{};
    for (final list in lists) {
      if (_selectedAudienceListIds.contains(list.group.id)) {
        memberIds.addAll(list.members.map((member) => member.id));
      }
    }
    return memberIds.length;
  }

  String _audienceLabel(List<GroupWithMembers> lists) {
    if (_selectedAudienceListIds.isEmpty) return 'All connections';
    final selected = lists
        .where((list) => _selectedAudienceListIds.contains(list.group.id))
        .toList();
    if (selected.isEmpty) return 'Limited audience — review selection';
    final people = _audienceMemberCount(lists);
    if (selected.length == 1) {
      return '${selected.single.group.name} · '
          '$people ${people == 1 ? 'person' : 'people'}';
    }
    return '${selected.length} lists · '
        '$people ${people == 1 ? 'person' : 'people'}';
  }

  Future<void> _showAudiencePicker() async {
    List<GroupWithMembers> lists;
    try {
      lists = await ref.read(groupsWithMembersProvider.future);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load your lists')),
        );
      }
      return;
    }
    if (!mounted) return;

    if (lists.isEmpty) {
      await context.push('/groups');
      ref.invalidate(groupsWithMembersProvider);
      return;
    }

    final validIds = lists.map((list) => list.group.id).toSet();
    final pending = Set<String>.from(_selectedAudienceListIds)
      ..retainAll(validIds);
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Choose audience',
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(
                          sheetContext,
                          Set<String>.from(pending),
                        ),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'Lists are private. People can see the post, not the '
                    'name of the list they are in.',
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      CheckboxListTile(
                        value: pending.isEmpty,
                        onChanged: (_) => setSheetState(pending.clear),
                        secondary: const Icon(Icons.people_outline),
                        title: const Text('All connections'),
                        subtitle: const Text('Your current sharing default'),
                      ),
                      const Divider(height: 1),
                      for (final list in lists)
                        CheckboxListTile(
                          value: pending.contains(list.group.id),
                          onChanged: list.members.isEmpty
                              ? null
                              : (selected) => setSheetState(() {
                                    if (selected == true) {
                                      pending.add(list.group.id);
                                    } else {
                                      pending.remove(list.group.id);
                                    }
                                  }),
                          secondary: Icon(
                            Icons.lock_outline,
                            color: list.members.isEmpty
                                ? Theme.of(sheetContext).disabledColor
                                : null,
                          ),
                          title: Text(list.group.name),
                          subtitle: Text(
                            list.members.isEmpty
                                ? 'No connected members'
                                : '${list.members.length} '
                                    '${list.members.length == 1 ? 'person' : 'people'}',
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'List changes apply only to future posts.',
                          style: Theme.of(sheetContext).textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          Future.microtask(() async {
                            if (!mounted) return;
                            await context.push('/groups');
                            ref.invalidate(groupsWithMembersProvider);
                          });
                        },
                        child: const Text('Manage lists'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (picked != null && mounted) {
      _edit(() {
        _selectedAudienceListIds
          ..clear()
          ..addAll(picked);
      });
    }
  }

  Widget _buildAudienceSelector(AppColorTokens colors, ThemeData theme) {
    final lists = ref.watch(groupsWithMembersProvider);
    final subtitle = lists.when(
      data: _audienceLabel,
      loading: () => _selectedAudienceListIds.isEmpty
          ? 'All connections'
          : 'Loading selected audience…',
      error: (_, __) => _selectedAudienceListIds.isEmpty
          ? 'All connections'
          : 'Limited audience — tap to review',
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Material(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: Icon(
            _selectedAudienceListIds.isEmpty
                ? Icons.people_outline
                : Icons.lock_outline,
            color: colors.textSecondary,
          ),
          title: const Text('Audience'),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: _isPosting ? null : _showAudiencePicker,
        ),
      ),
    );
  }

  Future<void> _share() async {
    if (!_canShare) return;
    _draftTimer?.cancel();

    _edit(() {
      _isPosting = true;
      _uploadTotalFiles = _media.length;
      _uploadingFileIndex = _completedCount;
      _uploadProgress =
          _uploadTotalFiles == 0 ? 0.0 : _completedCount / _uploadTotalFiles;
    });

    try {
      final api = ref.read(apiServiceProvider);

      if (_media.isNotEmpty) {
        for (var i = 0; i < _media.length; i++) {
          final item = _media[i];
          if (item.completed != null) continue;

          final isVideo = item.isVideo;
          final file = item.file;
          final contentType = isVideo ? 'video/mp4' : 'image/jpeg';

          _edit(() => _uploadingFileIndex = i);

          // Get upload URL for this file
          final uploadData = await api.getUploadUrls(contentType);
          final uploads =
              (uploadData as List<dynamic>).cast<Map<String, dynamic>>();
          final upload = uploads[0];
          final uploadUrl = upload['upload_url'] as String;
          final key = upload['key'] as String;

          List<int> bytes;
          int? width;
          int? height;
          // For videos, a first-frame JPEG uploaded as a sibling key so
          // widgets / grid cells / press cards can render a still
          // without pulling the full mp4. Null for photos.
          List<int>? thumbnailBytes;
          if (isVideo) {
            // Strip GPS/location metadata from video
            final stripped = await stripVideoMetadata(file.path);
            bytes = await stripped.readAsBytes();
            // Clean up temp file if different from original
            if (stripped.path != file.path) {
              stripped.delete().ignore();
            }
            // Capture video dimensions for aspect ratio display
            try {
              final ctrl = VideoPlayerController.file(File(file.path));
              await ctrl.initialize();
              width = ctrl.value.size.width.toInt();
              height = ctrl.value.size.height.toInt();
              ctrl.dispose();
            } catch (_) {
              // Best effort — dimensions are optional
            }
            // Extract a first-frame JPEG thumbnail. Quality 75 is
            // plenty for widget-size rendering; position=-1 asks
            // video_compress to auto-pick a reasonable frame (avoids
            // a black splash frame at time=0 on some codecs).
            try {
              thumbnailBytes = await VideoCompress.getByteThumbnail(
                file.path,
                quality: 75,
                position: -1,
              );
            } catch (_) {
              // Best effort — older clients and videos posted before
              // this shipped will have a null thumbnail_url, and
              // surfaces that need a still will fall back to their
              // legacy behavior.
            }
          } else {
            final result = await compressImageForUpload(file.path);
            bytes = await applyFilterToImage(
              result.bytes,
              _filterFor(i),
              transform: _transformFor(i),
            );
            width = result.width;
            height = result.height;
          }

          // Per-file cancel token + stall watchdog.
          final cancelToken = CancelToken();
          final watchdog = UploadWatchdog(cancelToken: cancelToken);
          _watchdog = watchdog;

          try {
            await api.uploadBytes(
              uploadUrl,
              bytes,
              contentType,
              cancelToken: cancelToken,
              onSendProgress: (sent, total) {
                if (!mounted) return;
                watchdog.noteProgress();
                final fileFraction = total > 0 ? sent / total : 0.0;
                _edit(() {
                  _uploadProgress = (i + fileFraction) / _uploadTotalFiles;
                });
              },
            );
          } catch (e) {
            if (isUploadStallOrTimeout(e)) {
              throw const _UploadStalled();
            }
            rethrow;
          } finally {
            watchdog.stop();
            _watchdog = null;
          }

          // If we have a video thumbnail, upload it as a sibling asset
          // and attach its key to the post_media row. Failure here is
          // non-fatal — we'd rather ship the video without a stored
          // thumbnail than fail the whole post. Consumers (iOS widget,
          // _VideoStaticThumbnail) fall back gracefully when the URL
          // is null.
          String? thumbnailKey;
          if (isVideo && thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
            try {
              final thumbUploadData = await api.getUploadUrls('image/jpeg');
              final thumbUploads = (thumbUploadData as List<dynamic>)
                  .cast<Map<String, dynamic>>();
              final thumbUpload = thumbUploads[0];
              final thumbUploadUrl = thumbUpload['upload_url'] as String;
              thumbnailKey = thumbUpload['key'] as String;
              await api.uploadBytes(
                thumbUploadUrl,
                thumbnailBytes,
                'image/jpeg',
              );
            } catch (_) {
              thumbnailKey = null;
            }
          }

          item.completed = {
            'key': key,
            'media_type': isVideo ? 'video' : 'photo',
            // position is re-derived below at submit so reorders after
            // a partial upload still produce the right server ordering.
            if (width != null) 'width': width,
            if (height != null) 'height': height,
            if (thumbnailKey != null) 'thumbnail_key': thumbnailKey,
          };
        }
      }

      // 3. Create the post. Position is taken from the current order in
      // _media — this is the canonical "reorder works at submit time"
      // step. Even if the user dragged thumbnails after upload, the
      // server sees the final positions.
      final caption = _captionController.text.trim();
      final mediaPayload = _media.isEmpty
          ? null
          : [
              for (var i = 0; i < _media.length; i++)
                {...?_media[i].completed, 'position': i},
            ];
      if (_voiceCaption != null && _uploadedVoiceCaptionId == null) {
        final recording = _voiceCaption!;
        final bytes = await File(recording.path).readAsBytes();
        if (bytes.isEmpty || bytes.length > 2097152) {
          throw const FormatException(
              'The voice caption is too large. Please record it again.');
        }
        _uploadedVoiceCaptionId =
            await api.uploadVoiceCaption(bytes, recording.durationMs);
      }
      await api.createPost(
        caption: caption.isNotEmpty ? caption : null,
        media: mediaPayload,
        groupIds: _selectedAudienceListIds.isEmpty
            ? null
            : _selectedAudienceListIds.toList(),
        hideAfter24h: _hideAfter24h,
        voiceCaptionId: _uploadedVoiceCaptionId,
      );

      _published = true;
      await ref.read(draftProvider.notifier).settled;
      for (final path in _temporaryVoicePaths.toList()) {
        await _removeTemporaryVoice(path);
      }
      _draftTimer?.cancel();
      // Drop the draft we resumed from, if any.
      if (_resumingDraftId != null) {
        try {
          await ref.read(draftProvider.notifier).deleteDraft(_resumingDraftId!);
        } catch (_) {
          // The post is already published. Never retry it after a local
          // draft cleanup failure.
        }
        _resumingDraftId = null;
      }

      if (mounted) {
        await ref.read(feedNotifierProvider.notifier).refresh();
        // Also invalidate user posts so profile grid updates
        final currentUser = ref.read(authProvider).user;
        if (currentUser != null) {
          ref.invalidate(userPostsProvider(currentUser.id));
        }
        if (mounted) {
          setState(() => _allowPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) context.pop();
          });
        }
      }
    } on _UploadStalled {
      if (mounted) {
        _edit(() => _isPosting = false);
        await _showStallDialog();
      }
    } catch (e) {
      if (mounted) {
        _edit(() => _isPosting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to share: $e')));
      }
    } finally {
      if (mounted && _isPosting) _edit(() => _isPosting = false);
    }
  }

  Future<void> _showStallDialog() async {
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Slow connection'),
        content: const Text(
          'The upload is taking longer than expected. Save this post as a '
          'draft and try again later?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: const Text('Keep Trying'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'draft'),
            child: const Text('Save as Draft'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (action == 'retry') {
      // Resume from where we stalled; per-item `completed` is retained.
      await _share();
    } else if (action == 'draft') {
      await _saveCurrentAsDraft();
    }
  }

  bool get _hasDraftContent =>
      _media.isNotEmpty ||
      _captionController.text.trim().isNotEmpty ||
      _voiceCaption != null;

  Future<void> _removeTemporaryVoice(String path) async {
    if (!_temporaryVoicePaths.remove(path)) return;
    await ref.read(draftProvider.notifier).settled;
    try {
      await File(path).delete();
    } on FileSystemException catch (_) {
      // Temporary files can also be purged by the OS.
    }
  }

  static const _draftStatusMessages = [
    'Drafts save on this device',
    'Saving draft…',
    'Draft saved on this device',
    'Draft couldn’t be saved. Try again.',
  ];

  Widget _buildDraftStatus(AppColorTokens colors, ThemeData theme) {
    final message = _draftError ??
        (!_hasDraftContent
            ? _draftStatusMessages[0]
            : _draftSaved
                ? _draftStatusMessages[2]
                : _draftStatusMessages[1]);
    final style = theme.textTheme.bodySmall?.copyWith(
      color:
          _draftError == null ? colors.textSecondary : theme.colorScheme.error,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      // Reserve the tallest status at the current width and text scale, so
      // saving, success and errors never move the editor underneath it.
      child: Stack(
        children: [
          for (final status in _draftStatusMessages)
            Visibility(
              visible: status == message,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Text(status, style: style),
            ),
        ],
      ),
    );
  }

  void _edit(VoidCallback change) {
    setState(change);
    _scheduleDraftSave();
  }

  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    if (_published || _isPosting || _closing) return;
    _draftRevision++;
    if (_draftSaved) setState(() => _draftSaved = false);
    _draftTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_saveDraftSafely());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _draftTimer?.cancel();
      if (!_isPosting && !_published && !_closing) {
        unawaited(_saveDraftSafely());
      }
    }
  }

  Future<bool> _saveDraftSafely() async {
    if (_published) return true;
    final notifier = ref.read(draftProvider.notifier);
    final revision = _draftRevision;
    try {
      if (!_hasDraftContent) {
        if (_resumingDraftId != null) {
          await notifier.deleteDraft(_resumingDraftId!);
          _resumingDraftId = null;
        }
        return true;
      }
      final id =
          _resumingDraftId ??= DateTime.now().microsecondsSinceEpoch.toString();
      _draftCreatedAt ??= DateTime.now();
      final items = List<_ComposerMedia>.of(_media);
      final sourcePaths = items.map((m) => m.file.path).toList();
      final draft = PostDraft(
        id: id,
        caption: _captionController.text,
        voiceCaptionPath: _voiceCaption?.path,
        voiceCaptionDurationMs: _voiceCaption?.durationMs,
        isTextPost: _isTextPost,
        hideAfter24h: _hideAfter24h,
        localFilePaths: sourcePaths,
        videoFlags: items.map((m) => m.isVideo).toList(),
        completedMedia: const [],
        completedMediaByIndex: {
          for (var i = 0; i < items.length; i++)
            if (items[i].completed != null)
              i: Map<String, dynamic>.from(items[i].completed!),
        },
        nextFileIndex: 0,
        createdAt: _draftCreatedAt!,
        audienceListIds: _selectedAudienceListIds.toList(),
        filterIds: {
          for (var i = 0; i < items.length; i++)
            if (items[i].filter != null) i: items[i].filter!.id,
        },
        transforms: {
          for (var i = 0; i < items.length; i++)
            if (items[i].transform != null) i: items[i].transform!,
        },
      );
      final saved = await notifier.saveDraft(draft);
      if (!mounted) return true;
      if (_voiceCaption?.path == draft.voiceCaptionPath &&
          saved.voiceCaptionPath != null) {
        _voiceCaption = VoiceRecording(
            saved.voiceCaptionPath!, saved.voiceCaptionDurationMs!);
      }
      for (var i = 0; i < items.length; i++) {
        if (items[i].file.path == sourcePaths[i]) {
          items[i].file = XFile(saved.localFilePaths[i]);
        }
      }
      if (revision == _draftRevision) {
        setState(() {
          _draftSaved = true;
          _draftError = null;
        });
      }
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => _draftError = 'Draft couldn’t be saved. Try again.');
      }
      return false;
    }
  }

  Future<void> _closeComposer() async {
    if (_closing || _isPosting || _recordingVoice) return;
    _closing = true;
    _draftTimer?.cancel();
    final saved = await _saveDraftSafely();
    if (!mounted) return;
    if (!saved) {
      setState(() => _closing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t save draft. Please try again.')),
      );
      return;
    }
    for (final path in _temporaryVoicePaths.toList()) {
      await _removeTemporaryVoice(path);
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.pop();
    });
  }

  Future<void> _saveCurrentAsDraft() => _closeComposer();

  Future<void> _recoverOlderDrafts() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recover older drafts?'),
        content: const Text(
          'Older drafts weren’t tied to an account. Recover them to this '
          'account only if they’re yours.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Recover drafts'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(draftProvider.notifier).recoverLegacyDrafts();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Some older drafts couldn’t be recovered. Please retry.'),
        ));
      }
    }
  }

  Widget _buildDraftsBanner(AppColorTokens colors, ThemeData theme) {
    final drafts = ref.watch(draftProvider);
    // Hide the banner once the user has resumed a draft or picked fresh media.
    if (drafts.isEmpty ||
        _resumingDraftId != null ||
        _media.isNotEmpty ||
        _isTextPost) {
      return const SizedBox.shrink();
    }

    final count = drafts.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showDraftsPicker(drafts),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.drafts_outlined, color: colors.textPrimary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    count == 1
                        ? 'You have 1 unfinished post. Tap to resume.'
                        : 'You have $count unfinished posts. Tap to resume.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Icon(Icons.chevron_right, color: colors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showDraftsPicker(List<PostDraft> drafts) async {
    final picked = await showModalBottomSheet<PostDraft>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Resume draft',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            for (final d in drafts)
              ListTile(
                leading: const Icon(Icons.drafts_outlined),
                title: Text(
                  d.caption.isEmpty ? '(no caption)' : d.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${d.localFilePaths.length} item${d.localFilePaths.length == 1 ? '' : 's'}'
                  ' · uploaded ${d.uploadedMediaCount}/${d.localFilePaths.length}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ref.read(draftProvider.notifier).deleteDraft(d.id);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _resumeDraft(picked);
  }

  void _resumeDraft(PostDraft draft) {
    _edit(() {
      _resumingDraftId = draft.id;
      _draftCreatedAt = draft.createdAt;
      _hideAfter24h = draft.hideAfter24h;
      _captionController.text = draft.caption;
      _voiceCaption = draft.voiceCaptionPath == null
          ? null
          : VoiceRecording(
              draft.voiceCaptionPath!, draft.voiceCaptionDurationMs ?? 1000);
      _uploadedVoiceCaptionId = null;
      _isTextPost = draft.isTextPost;
      _selectedAudienceListIds
        ..clear()
        ..addAll(draft.audienceListIds);
      _media.clear();
      for (var i = 0; i < draft.localFilePaths.length; i++) {
        final filterId = draft.filterIds[i];
        _media.add(
          _ComposerMedia(
            file: XFile(draft.localFilePaths[i]),
            isVideo: i < draft.videoFlags.length ? draft.videoFlags[i] : false,
            filter: filterId != null ? FilmFilters.byId(filterId) : null,
            transform: draft.transforms[i],
            completed: draft.uploadedMediaAt(i) == null
                ? null
                : Map<String, dynamic>.from(draft.uploadedMediaAt(i)!),
          ),
        );
      }
      _uploadTotalFiles = _media.length;
      _uploadingFileIndex = _completedCount;
      _uploadProgress =
          _uploadTotalFiles == 0 ? 0.0 : _completedCount / _uploadTotalFiles;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final hasMedia = _media.isNotEmpty;
    final legacyDrafts = ref.watch(legacyDraftCountProvider).value ?? 0;
    final hasSavedDrafts = ref.watch(draftProvider).isNotEmpty;

    return PopScope(
      canPop: _allowPop || _published,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_closeComposer());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _isPosting || _closing || _recordingVoice
                ? null
                : _closeComposer,
          ),
          title: Text(
            _isTextPost ? 'New Text Post' : 'New Post',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            if (_isPosting && _uploadTotalFiles > 0)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 90,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: _uploadProgress,
                          minHeight: 4,
                          backgroundColor: colors.textPrimary.withValues(
                            alpha: 0.15,
                          ),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            colors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Uploading ${(_uploadingFileIndex + 1).clamp(1, _uploadTotalFiles)} of '
                      '$_uploadTotalFiles…',
                      style:
                          TextStyle(fontSize: 10, color: colors.textTertiary),
                    ),
                  ],
                ),
              )
            else
              TextButton(
                onPressed: _canShare ? _share : null,
                child: _isPosting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.textPrimary,
                        ),
                      )
                    : Text(
                        'Share',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: _canShare
                              ? colors.textPrimary
                              : colors.textTertiary,
                        ),
                      ),
              ),
          ],
        ),
        // Tap anywhere outside the caption field to dismiss the keyboard.
        // HitTestBehavior.translucent so taps on inactive areas (between
        // widgets) still close the keyboard, while taps on inner widgets
        // with their own gesture handlers still work normally.
        body: AbsorbPointer(
          absorbing: _closing || _isPosting,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDraftsBanner(colors, theme),
                  if (!_isTextPost &&
                      !hasMedia &&
                      !_showingPostTypePicker &&
                      (hasSavedDrafts || legacyDrafts > 0)) ...[
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: FilledButton.icon(
                        onPressed: _showPostTypePicker,
                        icon: const Icon(Icons.add),
                        label: const Text('Create a new post'),
                      ),
                    ),
                    if (legacyDrafts > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextButton.icon(
                          onPressed: _recoverOlderDrafts,
                          icon: const Icon(Icons.restore),
                          label: const Text('Recover older drafts'),
                        ),
                      ),
                  ],
                  if (_isTextPost || hasMedia) _buildDraftStatus(colors, theme),
                  if (_isTextPost) ...[
                    // Text post: large centered input
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: TextField(
                        controller: _captionController,
                        textCapitalization: TextCapitalization.sentences,
                        autofocus: true,
                        maxLines: null,
                        minLines: 6,
                        maxLength: _maxTextPostLength,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                        decoration: InputDecoration(
                          hintText: "What's on your mind?",
                          hintStyle: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            height: 1.4,
                            color: colors.textTertiary.withValues(alpha: 0.4),
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          suffixIcon: SpeechInputButton(
                            controller: _captionController,
                            maxLength: _maxTextPostLength,
                          ),
                        ),
                        onChanged: (_) => _edit(() {}),
                      ),
                    ),
                    // Option to switch to photo post
                    Center(
                      child: TextButton.icon(
                        onPressed: _showMediaSourcePicker,
                        icon: Icon(
                          Icons.add_photo_alternate_outlined,
                          color: colors.textTertiary,
                        ),
                        label: Text(
                          'Add photos instead',
                          style: TextStyle(color: colors.textTertiary),
                        ),
                      ),
                    ),
                    // Auto-hide toggle for text posts
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            size: 20,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Hide after 24 hours',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                          Switch.adaptive(
                            value: _hideAfter24h,
                            onChanged: (v) => _edit(() => _hideAfter24h = v),
                          ),
                        ],
                      ),
                    ),
                  ] else if (hasMedia) ...[
                    // Photo post: media strip + caption
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colors.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: colors.border, width: 0.5),
                      ),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 200,
                            // Strip is a horizontal ReorderableListView so users
                            // can long-press a thumbnail and drag to reposition
                            // it. Each child uses the stable [_ComposerMedia.id]
                            // as a Key — filter, transform, and upload state
                            // travel with the item across reorders for free.
                            child: ReorderableListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.all(8),
                              buildDefaultDragHandles: false,
                              proxyDecorator: (child, index, animation) =>
                                  Material(
                                elevation: 6,
                                color: Colors.transparent,
                                shadowColor: Colors.black54,
                                borderRadius: BorderRadius.circular(10),
                                child: child,
                              ),
                              // Reorder is disabled mid-upload — the share/upload
                              // path indexes into _media by position and the
                              // stall-resume path assumes ordering is stable.
                              onReorderItem:
                                  _isPosting ? (_, __) {} : _reorderMedia,
                              itemCount: _media.length,
                              itemBuilder: (context, index) {
                                final item = _media[index];
                                return Padding(
                                  // Spacing between items (replaces the old
                                  // ListView.separated separator).
                                  key: ValueKey(item.id),
                                  padding: EdgeInsets.only(
                                    right: index == _media.length - 1 ? 0 : 8,
                                  ),
                                  child: ReorderableDelayedDragStartListener(
                                    index: index,
                                    enabled: !_isPosting,
                                    child: GestureDetector(
                                      onTap: item.isVideo
                                          ? null
                                          : () => _showFilterOverlay(index),
                                      child: Stack(
                                        children: [
                                          ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            child: item.isVideo
                                                ? _VideoFilePreview(
                                                    path: item.file.path,
                                                    width: 150,
                                                    height: 200,
                                                  )
                                                : FilteredImage(
                                                    filter: _filterFor(index),
                                                    width: 150,
                                                    height: 200,
                                                    // Apply rotation + scale from
                                                    // the user's edit so the
                                                    // thumbnail in this strip
                                                    // matches what the post will
                                                    // look like in the feed.
                                                    // ClipRect keeps the rotated/
                                                    // zoomed image inside the
                                                    // 150×200 tile. Offset (pan)
                                                    // is skipped: its units
                                                    // (preview-container px) don't
                                                    // translate cleanly to a 150px
                                                    // tile, and typical pans are
                                                    // small enough that omitting
                                                    // them is visually fine.
                                                    child: ClipRect(
                                                      child: Transform.scale(
                                                        scale: _transformFor(
                                                          index,
                                                        ).scale,
                                                        child: Transform.rotate(
                                                          angle: _transformFor(
                                                            index,
                                                          ).rotation,
                                                          child: Image.file(
                                                            File(
                                                                item.file.path),
                                                            width: 150,
                                                            height: 200,
                                                            fit: BoxFit.cover,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                          if (item.isVideo)
                                            Positioned.fill(
                                              child: Center(
                                                child: Container(
                                                  width: 36,
                                                  height: 36,
                                                  decoration:
                                                      const BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: Colors.black54,
                                                  ),
                                                  child: const Icon(
                                                    Icons.videocam,
                                                    size: 18,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          Positioned(
                                            top: 4,
                                            right: 4,
                                            child: GestureDetector(
                                              onTap: () => _removeMedia(index),
                                              child: Container(
                                                width: 24,
                                                height: 24,
                                                decoration: const BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: Colors.black54,
                                                ),
                                                child: const Icon(
                                                  Icons.close,
                                                  size: 14,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                              // Trailing "+" affordance lives outside the
                              // reorderable list because ReorderableListView
                              // expects every child to be reorderable. Wrapping
                              // the strip in a Row keeps the add button visually
                              // adjacent without breaking that contract.
                            ),
                          ),
                          if (_media.length < _maxMedia)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: GestureDetector(
                                  onTap: _showMediaSourcePicker,
                                  child: Container(
                                    width: 150,
                                    height: 60,
                                    decoration: BoxDecoration(
                                      color: colors.card,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: colors.border,
                                        width: 0.5,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.add,
                                          color: colors.textTertiary,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'Add',
                                          style: TextStyle(
                                            color: colors.textTertiary,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                            child: Text(
                              '${_media.length}/$_maxMedia items'
                              '${_media.length > 1 ? "  ·  Long-press a photo to reorder" : ""}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Filter picker (applies to all photos at once; tap a
                    // thumbnail above for per-image control in the overlay).
                    // Driven off the first photo in the strip — its filter is
                    // the "shared" selection users see highlighted.
                    if (_media.any((m) => !m.isVideo))
                      Builder(
                        builder: (_) {
                          final firstPhotoIdx = _media.indexWhere(
                            (m) => !m.isVideo,
                          );
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: FilterPicker(
                              imagePath: _media[firstPhotoIdx].file.path,
                              selectedFilter: _filterFor(firstPhotoIdx),
                              onFilterChanged: (f) {
                                _edit(() {
                                  // Apply filter to ALL photos
                                  for (var i = 0; i < _media.length; i++) {
                                    if (!_media[i].isVideo) {
                                      _media[i].filter = f.isNone ? null : f;
                                      _media[i].completed = null;
                                    }
                                  }
                                });
                              },
                            ),
                          );
                        },
                      ),

                    // Caption
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _captionController,
                        textCapitalization: TextCapitalization.sentences,
                        maxLines: 5,
                        minLines: 3,
                        maxLength: _maxCaptionLength,
                        decoration: InputDecoration(
                          hintText: 'Write a caption...',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          counterText: '',
                          suffixIcon: SpeechInputButton(
                            controller: _captionController,
                            maxLength: _maxCaptionLength,
                          ),
                        ),
                      ),
                    ),

                    // Auto-hide toggle
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            size: 20,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Hide after 24 hours',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                          Switch.adaptive(
                            value: _hideAfter24h,
                            onChanged: (v) => _edit(() => _hideAfter24h = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_media.any((item) => !item.isVideo) ||
                      _voiceCaption != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: VoiceCaptionEditor(
                          value: _voiceCaption,
                          enabled: !_isPosting,
                          onChanged: (recording) {
                            final previousPath = _voiceCaption?.path;
                            if (recording?.temporary == true) {
                              _temporaryVoicePaths.add(recording!.path);
                            }
                            _edit(() {
                              _voiceCaption = recording;
                              _uploadedVoiceCaptionId = null;
                            });
                            if (previousPath != null &&
                                previousPath != recording?.path) {
                              unawaited(_removeTemporaryVoice(previousPath));
                            }
                            if (WidgetsBinding.instance.lifecycleState !=
                                AppLifecycleState.resumed) {
                              unawaited(_saveDraftSafely());
                            }
                          },
                          onRecordingChanged: (recording) =>
                              setState(() => _recordingVoice = recording),
                        )),
                  if (_voiceCaption != null &&
                      !_media.any((item) => !item.isVideo))
                    const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                            'Add a photo or remove the voice caption to share.')),
                  if (_isTextPost || hasMedia)
                    _buildAudienceSelector(colors, theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the first frame of a local video file as a thumbnail.
class _VideoFilePreview extends StatefulWidget {
  final String path;
  final double width;
  final double height;

  const _VideoFilePreview({
    required this.path,
    required this.width,
    required this.height,
  });

  @override
  State<_VideoFilePreview> createState() => _VideoFilePreviewState();
}

class _VideoFilePreviewState extends State<_VideoFilePreview> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
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
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const ColoredBox(color: Colors.black12),
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _controller.value.size.width,
          height: _controller.value.size.height,
          child: VideoPlayer(_controller),
        ),
      ),
    );
  }
}
