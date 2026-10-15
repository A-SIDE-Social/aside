import 'dart:async';
import 'dart:io';

import 'package:aside/models/post_draft.dart';
import 'package:aside/models/user.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/providers/draft_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fixtures.dart';

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        status: AuthStatus.authenticated,
        user: User.fromJson(userJson(id: 'alice')),
      );

  void switchTo(String id) => state = AuthState(
        status: AuthStatus.authenticated,
        user: User.fromJson(userJson(id: id)),
      );
}

class _DelayedStorage extends DraftStorage {
  _DelayedStorage(Directory directory)
      : super(directory: () async => directory);
  final gate = Completer<void>();
  bool delay = true;

  @override
  Future<List<PostDraft>> read(String owner) async {
    if (delay) {
      delay = false;
      await gate.future;
    }
    return super.read(owner);
  }
}

class _FailOnceStorage extends DraftStorage {
  _FailOnceStorage(Directory directory)
      : super(directory: () async => directory);
  bool fail = true;
  @override
  Future<void> write(String owner, List<PostDraft> drafts) async {
    if (fail) {
      fail = false;
      throw const FileSystemException('Storage full');
    }
    await super.write(owner, drafts);
  }
}

PostDraft _draft(String id, {List<String> paths = const []}) => PostDraft(
      id: id,
      caption: id,
      isTextPost: paths.isEmpty,
      localFilePaths: paths,
      videoFlags: paths.map((_) => false).toList(),
      completedMedia: const [],
      nextFileIndex: 0,
      createdAt: DateTime(2026, 10, 14),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Auth auth;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('aside-drafts-');
    auth = _Auth();
  });

  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  DraftNotifier open({DraftStorage? storage}) {
    container = ProviderContainer(overrides: [
      authProvider.overrideWith(() => auth),
      draftStorageProvider.overrideWithValue(
        storage ?? DraftStorage(directory: () async => directory),
      ),
    ]);
    return container.read(draftProvider.notifier);
  }

  test('an early save waits for loading and preserves existing drafts',
      () async {
    final storage = _DelayedStorage(directory);
    await storage.write('alice', [_draft('older')]);
    final notifier = open(storage: storage);
    final saving = notifier.saveDraft(_draft('newer'));
    storage.gate.complete();
    await saving;
    expect(container.read(draftProvider).map((d) => d.id),
        containsAll(['older', 'newer']));
  });

  test('durable copies survive temporary-file deletion and reordering',
      () async {
    final first = File('${directory.path}/camera-a.jpg')
      ..writeAsBytesSync([1, 2]);
    final second = File('${directory.path}/camera-b.jpg')
      ..writeAsBytesSync([3, 4]);
    final notifier = open();
    final saved = await notifier.saveDraft(
      _draft('photos', paths: [first.path, second.path]),
    );
    await first.delete();
    await second.delete();
    final reordered = await notifier.saveDraft(
      _draft('photos', paths: saved.localFilePaths.reversed.toList()),
    );
    expect(await File(reordered.localFilePaths.first).readAsBytes(), [3, 4]);
    expect(await File(reordered.localFilePaths.last).readAsBytes(), [1, 2]);
    await notifier.deleteDraft('photos');
    expect(await File(saved.localFilePaths.first).exists(), false);
  });

  test('account switching never shows another account’s drafts', () async {
    final notifier = open();
    await notifier.saveDraft(_draft('alice-draft'));
    auth.switchTo('bob');
    container.read(draftProvider);
    await container.read(draftProvider.notifier).ready;
    expect(container.read(draftProvider), isEmpty);
    await container.read(draftProvider.notifier).saveDraft(_draft('bob-draft'));
    auth.switchTo('alice');
    container.read(draftProvider);
    await container.read(draftProvider.notifier).ready;
    expect(container.read(draftProvider).single.id, 'alice-draft');
  });

  test('a failed save does not poison later saves', () async {
    final notifier = open(storage: _FailOnceStorage(directory));
    await expectLater(notifier.saveDraft(_draft('retry')),
        throwsA(isA<FileSystemException>()));
    await notifier.saveDraft(_draft('retry'));
    expect(container.read(draftProvider).single.id, 'retry');
  });

  test('unowned legacy drafts remain stored without leaking across accounts',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('post_drafts', [_draft('legacy').encode()]);
    final notifier = open();
    await notifier.ready;
    expect(container.read(draftProvider), isEmpty);
    expect(prefs.getStringList('post_drafts'), hasLength(1));
  });

  test('explicit recovery assigns legacy drafts without losing their content',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs
        .setStringList('post_drafts', [_draft('older-version').encode()]);
    final notifier = open();
    await notifier.ready;
    await notifier.recoverLegacyDrafts();
    expect(container.read(draftProvider).single.caption, 'older-version');
    expect(prefs.getStringList('post_drafts'), isEmpty);
    auth.switchTo('bob');
    container.read(draftProvider);
    await container.read(draftProvider.notifier).ready;
    expect(container.read(draftProvider), isEmpty);
  });

  test('expiry and sparse uploaded media retain their positions', () {
    final draft = PostDraft(
      id: 'reordered',
      caption: 'A carousel',
      isTextPost: false,
      hideAfter24h: true,
      localFilePaths: const ['pending.jpg', 'done.jpg'],
      videoFlags: const [false, false],
      completedMedia: const [],
      completedMediaByIndex: const {
        1: {'key': 'already-uploaded'}
      },
      nextFileIndex: 0,
      createdAt: DateTime(2026, 10, 14),
      audienceListIds: const ['private-list'],
      filterIds: const {0: 'slate', 1: 'clean_mono'},
    );
    final restored = PostDraft.decode(draft.encode());
    expect(restored.hideAfter24h, true);
    expect(restored.uploadedMediaAt(0), isNull);
    expect(restored.uploadedMediaAt(1), {'key': 'already-uploaded'});
    expect(restored.uploadedMediaCount, 1);
    expect(restored.localFilePaths, ['pending.jpg', 'done.jpg']);
    expect(restored.audienceListIds, ['private-list']);
    expect(restored.filterIds, {0: 'slate', 1: 'clean_mono'});
  });
}
