import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/post_draft.dart';
import 'auth_provider.dart';

/// Keeps draft media outside the image picker's temporary directory, which
/// the OS can purge between editing sessions.
class DraftStorage {
  DraftStorage({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  String _key(String owner) => 'post_drafts:${Uri.encodeComponent(owner)}';

  Future<List<PostDraft>> read(String owner) async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = <PostDraft>[];
    for (final raw in prefs.getStringList(_key(owner)) ?? <String>[]) {
      try {
        drafts.add(PostDraft.decode(raw));
      } on FormatException {
        // One damaged record must not prevent opening the other drafts.
      } on TypeError {
        // Ignore incomplete records from an interrupted older save.
      }
    }
    return drafts;
  }

  Future<void> write(String owner, List<PostDraft> drafts) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setStringList(
      _key(owner),
      drafts.map((draft) => draft.encode()).toList(),
    );
    if (!saved) throw const FileSystemException('Could not save draft');
  }

  Future<Directory> _draftDirectory(String owner, String id) async => Directory(
        '${(await _directory()).path}/post_drafts/'
        '${sha256.convert(utf8.encode(owner))}/'
        '${sha256.convert(utf8.encode(id))}',
      );

  Future<PostDraft> preserveMedia(String owner, PostDraft draft) async {
    if (draft.localFilePaths.isEmpty) return draft;
    final directory = await _draftDirectory(owner, draft.id);
    await directory.create(recursive: true);
    final paths = <String>[];
    for (final path in draft.localFilePaths) {
      final source = File(path);
      if (source.parent.path == directory.path) {
        if (!await source.exists()) {
          throw const FileSystemException('A draft photo or video is missing');
        }
        paths.add(path);
        continue;
      }
      final stat = await source.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const FileSystemException('A draft photo or video is missing');
      }
      final name = sha256.convert(utf8.encode(
        '$path:${stat.size}:${stat.modified.microsecondsSinceEpoch}',
      ));
      final suffix = path.split('.').last.toLowerCase();
      final extension =
          RegExp(r'^[a-z0-9]{1,5}$').hasMatch(suffix) ? '.$suffix' : '.media';
      final destination = File('${directory.path}/$name$extension');
      if (!await destination.exists()) {
        final temporary = await source.copy('${destination.path}.partial');
        await temporary.rename(destination.path);
      }
      paths.add(destination.path);
    }
    return draft.withLocalFiles(paths);
  }

  Future<void> removeMedia(String owner, String id) async {
    final directory = await _draftDirectory(owner, id);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

final draftStorageProvider = Provider<DraftStorage>((ref) => DraftStorage());

/// Account-scoped drafts. Serialize writes and wait for the initial load so
/// an early save cannot overwrite drafts still being read from disk.
class DraftNotifier extends Notifier<List<PostDraft>> {
  String? _owner;
  Future<void> _pending = Future.value();
  Future<void> _ready = Future.value();
  int _loadGeneration = 0;

  @override
  List<PostDraft> build() {
    final owner = ref.watch(authProvider.select((auth) => auth.user?.id));
    _owner = owner;
    final generation = ++_loadGeneration;
    if (owner != null) {
      final storage = ref.read(draftStorageProvider);
      _ready = _pending.then((_) => storage.read(owner)).then((drafts) {
        if (ref.mounted && _owner == owner && generation == _loadGeneration) {
          state = drafts;
        }
      });
    } else {
      _ready = Future.value();
    }
    return const [];
  }

  Future<void> get ready => _ready;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<PostDraft> saveDraft(PostDraft draft) {
    final owner = _owner;
    final ready = _ready;
    final storage = ref.read(draftStorageProvider);
    if (owner == null) {
      return Future.error(StateError('Sign in to save a draft'));
    }
    return _serialize(() async {
      await ready;
      final saved = await storage.preserveMedia(owner, draft);
      final existing = await storage.read(owner);
      final next = [saved, ...existing.where((d) => d.id != saved.id)]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await storage.write(owner, next);
      if (ref.mounted && _owner == owner) state = next;
      return saved;
    });
  }

  Future<void> deleteDraft(String id) {
    final owner = _owner;
    final ready = _ready;
    final storage = ref.read(draftStorageProvider);
    if (owner == null) return Future.value();
    return _serialize(() async {
      await ready;
      final next =
          (await storage.read(owner)).where((d) => d.id != id).toList();
      await storage.write(owner, next);
      if (ref.mounted && _owner == owner) state = next;
      try {
        await storage.removeMedia(owner, id);
      } on FileSystemException {
        // A successful share must not fail because cached files remain.
      }
    });
  }

  Future<void> refresh() async {
    await _ready;
    final owner = _owner;
    if (owner == null) return;
    final drafts = await ref.read(draftStorageProvider).read(owner);
    if (ref.mounted && _owner == owner) state = drafts;
  }

  /// Older versions did not record an owner. Recovery requires an explicit
  /// ownership confirmation in the composer before assigning those drafts.
  Future<void> recoverLegacyDrafts() async {
    final owner = _owner;
    if (owner == null) throw StateError('Sign in to recover drafts');
    final prefs = await SharedPreferences.getInstance();
    final raw = List<String>.of(prefs.getStringList('post_drafts') ?? []);
    for (final record in raw) {
      if (_owner != owner) throw StateError('Account changed during recovery');
      final draft = PostDraft.decode(record);
      await saveDraft(draft);
      // Remove each legacy record only after its owned copy is durable.
      final remaining = List<String>.of(
        prefs.getStringList('post_drafts') ?? [],
      )..remove(record);
      if (!await prefs.setStringList('post_drafts', remaining)) {
        throw const FileSystemException('Could not finish draft recovery');
      }
    }
    if (ref.mounted) ref.invalidate(legacyDraftCountProvider);
  }

  Future<void> clearAll() async {
    await _ready;
    for (final draft in List<PostDraft>.of(state)) {
      await deleteDraft(draft.id);
    }
  }
}

final draftProvider =
    NotifierProvider<DraftNotifier, List<PostDraft>>(DraftNotifier.new);

/// Legacy records have no account ownership. Leave them untouched rather
/// than exposing another account's drafts after an account switch.
Future<List<String>> readRawDrafts() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList('post_drafts') ?? const [];
}

final legacyDraftCountProvider =
    FutureProvider<int>((ref) async => (await readRawDrafts()).length);
