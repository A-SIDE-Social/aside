// Composes the local [SignalClient] (key storage + generation) with
// the remote [ApiService] (server key registry). Calling code —
// sign-in flow, background OTPK topper-upper, sign-out wipe —
// interacts with this class rather than hitting both sides itself.
//
// Design note: we assume `SignalClient.hasKeys() == true` implies
// the keys are already uploaded to the server. That saves a no-op
// re-upload on every sign-in but relies on [ensureKeysInitialized]
// wiping local state if the server call ever fails mid-flight (see
// the try/catch in that method). Phase 2 could track a persistent
// "last_uploaded_version" for stricter reconciliation.

import '../network/api_service.dart';
import 'signal_client.dart';

class KeyRegistrySync {
  final SignalClient _signal;
  final ApiService _api;

  KeyRegistrySync(this._signal, this._api);

  /// Bootstrap on sign-in. If no keys exist locally, generate a fresh
  /// identity + signed prekey + OTPK batch, persist them, and upload
  /// the public halves. Safe to call on every sign-in — a no-op if
  /// the device is already provisioned.
  ///
  /// Returns true if this call created new keys, false if it found
  /// existing ones and trusted them as already-uploaded.
  ///
  /// If the server upload fails, the just-generated local keys are
  /// wiped so the next call retries cleanly rather than leaving a
  /// split-brain state (local has keys, server doesn't).
  Future<bool> ensureKeysInitialized({
    int otpkCount = SignalClient.defaultOtpkBatch,
  }) async {
    if (await _signal.hasKeys()) return false;

    final bundle = await _signal.generateInitialKeys(otpkCount: otpkCount);
    try {
      await _api.uploadDeviceKeys(bundle.toJson());
    } catch (_) {
      await _signal.wipeKeys();
      rethrow;
    }
    return true;
  }

  /// Tops up the OTPK and Kyber prekey pools if either has dropped
  /// below its threshold. Uploads the combined batch in a single
  /// request so a partial replenishment is still transactional on
  /// the server. Returns (otpks_added, kyber_added).
  Future<({int otpks, int kyber})> replenishIfNeeded({
    int otpkThreshold = SignalClient.defaultOtpkThreshold,
    int otpkBatchSize = SignalClient.defaultOtpkBatch,
    int kyberThreshold = SignalClient.defaultKyberThreshold,
    int kyberBatchSize = SignalClient.defaultKyberBatch,
  }) async {
    final freshOtpks = await _signal.replenishOneTimePreKeys(
      threshold: otpkThreshold,
      batchSize: otpkBatchSize,
    );
    final freshKyber = await _signal.replenishKyberPreKeys(
      threshold: kyberThreshold,
      batchSize: kyberBatchSize,
    );
    if (freshOtpks.isEmpty && freshKyber.isEmpty) {
      return (otpks: 0, kyber: 0);
    }

    await _api.replenishPreKeys(
      oneTimePreKeys: freshOtpks.map((k) => k.toJson()).toList(growable: false),
      kyberPreKeys: freshKyber.map((k) => k.toJson()).toList(growable: false),
    );
    return (otpks: freshOtpks.length, kyber: freshKyber.length);
  }

  /// Generates a fresh signed prekey, persists, and uploads. Called
  /// by the weekly rotation scheduler (Phase 2).
  Future<void> rotateSignedPreKey() async {
    final newSpk = await _signal.rotateSignedPreKey();
    await _api.rotateSignedPreKey(newSpk.toJson());
  }

  /// Sign-out cleanup: revoke on server + wipe locally. Safe to call
  /// even if no keys exist (the server side is idempotent).
  Future<void> resetKeys() async {
    // Server first so any stale keys are neutralized even if local
    // wipe somehow fails partway.
    await _api.revokeDeviceKeys();
    await _signal.wipeKeys();
  }

  /// Fetches a peer's bundle for session setup. Thin passthrough,
  /// exposed here so crypto-path callers only ever talk to this
  /// class rather than reaching into ApiService directly.
  Future<Map<String, dynamic>> fetchPeerKeyBundle(String userId) {
    return _api.getUserKeyBundle(userId);
  }
}
