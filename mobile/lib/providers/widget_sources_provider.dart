import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/app_group_channel.dart';
import '../core/config/env.dart';
import '../core/storage/secure_storage.dart';
import 'api_provider.dart';
import 'auth_provider.dart';
import 'group_members_provider.dart';

/// Configuration choices only. Widgets fetch the selected post independently;
/// changing the feed filter cannot change an existing widget's selection.
final widgetSourcesProvider =
    FutureProvider<List<Map<String, String>>>((ref) async {
  final owner = ref.watch(authProvider.select((auth) => auth.user?.id));
  if (!Platform.isIOS || owner == null) return [];
  final groups = await ref.watch(groupsWithMembersProvider.future);
  final friends = await ref.read(apiServiceProvider).getMutualFollows() as List;
  if (!ref.mounted || ref.read(authProvider).user?.id != owner) return [];
  final sources = <Map<String, String>>[
    for (final friend in friends)
      {
        'id': friend['id'] as String,
        'targetId': friend['id'] as String,
        'name': friend['display_name'] as String,
        'kind': 'friend',
        'ownerId': owner
      },
    for (final group in groups)
      {
        'id': group.group.id,
        'targetId': group.group.id,
        'name': group.group.name,
        'kind': 'list',
        'ownerId': owner
      },
  ];
  final storage = SecureStorage();
  var credential = await storage.getRefreshToken();
  if (!ref.mounted ||
      ref.read(authProvider).user?.id != owner ||
      credential == null) {
    return [];
  }
  String widgetToken;
  try {
    widgetToken =
        await ref.read(apiServiceProvider).createWidgetSession(credential);
  } catch (_) {
    final rotated = await storage.getRefreshToken();
    if (!ref.mounted ||
        ref.read(authProvider).user?.id != owner ||
        rotated == null ||
        rotated == credential) {
      rethrow;
    }
    widgetToken =
        await ref.read(apiServiceProvider).createWidgetSession(rotated);
  }
  if (!ref.mounted || ref.read(authProvider).user?.id != owner) return [];
  await AppGroupChannel.setWidgetSession(
      userId: owner, token: widgetToken, baseURL: Env.apiBaseUrl);
  if (!ref.mounted || ref.read(authProvider).user?.id != owner) return [];
  await AppGroupChannel.syncWidgetSources(owner, sources);
  return sources;
});
