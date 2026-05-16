import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory LRU cache for decrypted E2EE attachment plaintext.
///
/// Keyed by the attachment's blob key (e.g. `dm/<uuid>`) — which is a
/// stable server-assigned identifier for the ciphertext blob, unique
/// per send. Hitting this cache skips a presigned GET + ChaCha20
/// decrypt round-trip on every scroll-into-view, which is otherwise
/// very visible in E2EE threads: a user scrolling back through older
/// photos sees each one blink through a spinner every time it comes
/// back on-screen, because `ListView.builder` disposes the bubble
/// widget when it leaves the cacheExtent.
///
/// Privacy-relevant: this is a **memory-only** cache. We never write
/// decrypted attachment bytes to disk — the `flutter_secure_storage`
/// keeps session/identity keys there, but plaintext attachments are
/// treated as ephemeral. The cache is cleared when auth transitions
/// (sign-out or account switch) so a subsequent user of the same
/// device can't read the previous user's photos out of Flutter's
/// engine heap. See `_authListenableProvider` in `app.dart` for the
/// invalidate wiring.
///
/// Bounded to [maxEntries] via basic LRU eviction — chosen small
/// enough that a very active DM thread doesn't fill the engine heap
/// with full-resolution JPEGs, but large enough that ordinary
/// scroll-back through a few screens of history is always a hit.
class AttachmentPlaintextCache {
  AttachmentPlaintextCache({this.maxEntries = 40});

  final int maxEntries;
  final Map<String, Uint8List> _bytes = <String, Uint8List>{};
  // Oldest-first. We use a list rather than a LinkedHashMap's
  // natural order because we want to move keys to the tail on
  // `get` (classic LRU), and Dart's built-in maps don't expose a
  // reorder primitive.
  final List<String> _order = <String>[];

  Uint8List? get(String key) {
    final bytes = _bytes[key];
    if (bytes == null) return null;
    _order.remove(key);
    _order.add(key);
    return bytes;
  }

  void put(String key, Uint8List value) {
    if (_bytes.containsKey(key)) {
      _order.remove(key);
    } else if (_bytes.length >= maxEntries) {
      final evicted = _order.removeAt(0);
      _bytes.remove(evicted);
    }
    _bytes[key] = value;
    _order.add(key);
  }

  void clear() {
    _bytes.clear();
    _order.clear();
  }

  int get length => _bytes.length;
}

/// Global instance used by message bubbles. A plain `Provider` (not
/// autoDispose) so the cache survives leaving + returning to the
/// conversation list. `ref.invalidate` from the auth listener tears
/// it down on sign-out / account switch.
final attachmentPlaintextCacheProvider =
    Provider<AttachmentPlaintextCache>((ref) => AttachmentPlaintextCache());
