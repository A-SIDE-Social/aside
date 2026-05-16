import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// The user's current personal invite link.
class InviteLink {
  /// Opaque 12-char lowercase alphanumeric slug — the path of the URL.
  final String slug;

  /// Fully-qualified shareable URL of the form
  /// `<configured-app-url>/<slug>`. The server constructs this so
  /// host changes don't require a client release.
  final String url;

  const InviteLink({required this.slug, required this.url});

  factory InviteLink.fromJson(Map<String, dynamic> json) {
    return InviteLink(
      slug: json['slug'] as String,
      url: json['url'] as String,
    );
  }
}

/// Personal-invite-link provider.
///
/// Fetches the caller's slug on first read and caches it. `regenerate()`
/// rotates the slug server-side and updates the state in place, which
/// matters because every Share / QR consumer of this provider needs
/// to see the new value immediately (the old URL stops working as
/// soon as the rotate request returns).
///
/// `AsyncNotifier` rather than `FutureProvider` so the regenerate
/// mutation can flip state to a loading frame and back to data
/// without invalidating callers — keeps the UI on the same screen
/// with a momentary spinner rather than dropping the user back to
/// an empty state.
class InviteLinkNotifier extends AsyncNotifier<InviteLink> {
  @override
  Future<InviteLink> build() async {
    final api = ref.read(apiServiceProvider);
    final data = await api.getInviteLink();
    return InviteLink.fromJson(data);
  }

  /// Rotate the slug. Old URL/QR stop working at the moment the server
  /// commits the new slug; the UI updates the moment this future
  /// resolves.
  Future<InviteLink> regenerate() async {
    state = const AsyncValue.loading();
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.regenerateInviteLink();
      final link = InviteLink.fromJson(data);
      state = AsyncValue.data(link);
      return link;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      rethrow;
    }
  }
}

final inviteLinkProvider =
    AsyncNotifierProvider<InviteLinkNotifier, InviteLink>(
        InviteLinkNotifier.new);
