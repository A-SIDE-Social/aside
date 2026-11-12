// Composes the local [SignalClient] (key storage + generation) with
// the remote [ApiService] (server key registry). Calling code —
// sign-in flow, background OTPK topper-upper, sign-out wipe —
// interacts with this class rather than hitting both sides itself.
//
// Local key presence is not an upload receipt. Reconcile saved public halves
// on sign-in and retain private material after every ambiguous failure.

import 'dart:convert';

import 'package:dio/dio.dart';
import '../network/api_service.dart';
import 'signal_client.dart';

class KeyRecoveryRequired implements Exception {
  final String message;
  const KeyRecoveryRequired(this.message);
  @override
  String toString() => message;
}

class _KeyWork {
  Future<bool>? initialization;
  String? owner;
  Future<void>? reset;
  Future<void>? recovery;
  int recoveryEpoch = 0;
  ({String owner, Map<String, dynamic> bundle, String ticket})? confirmation;
  Future<({int otpks, int kyber})>? replenishment;
  ({List<PublicOneTimePreKey> otpks, List<PublicKyberPreKey>? kyber})? pending;
}

class KeyRegistrySync {
  static final _workBySignal = Expando<_KeyWork>();
  final SignalClient _signal;
  final ApiService _api;
  final _KeyWork _work;

  KeyRegistrySync(SignalClient signal, ApiService api)
      : _signal = signal,
        _api = api,
        _work = _workBySignal[signal] ??= _KeyWork();

  /// Bootstrap or reconcile this account's saved key material. Returns true
  /// only if a new local identity was needed. Conflicts require manual recovery;
  /// this method never revokes or wipes keys.
  Future<bool> ensureKeysInitialized({
    required String ownerUserId,
    int otpkCount = SignalClient.defaultOtpkBatch,
  }) {
    if (_work.reset != null ||
        _work.recovery != null ||
        _work.confirmation != null) {
      return Future.error(StateError('Encryption setup is stopping'));
    }
    final pending = _work.initialization;
    if (pending != null) {
      if (_work.owner != ownerUserId) {
        return Future.error(const KeyRecoveryRequired(
            'Encryption keys require account recovery'));
      }
      return pending;
    }
    _work.owner = ownerUserId;
    late final Future<bool> operation;
    operation = _initialize(ownerUserId, otpkCount).whenComplete(() {
      if (identical(_work.initialization, operation)) {
        _work.initialization = null;
        _work.owner = null;
      }
    });
    _work.initialization = operation;
    return operation;
  }

  Future<bool> _initialize(String ownerUserId, int otpkCount) async {
    final replenishment = _work.replenishment;
    if (replenishment != null) {
      try {
        await replenishment;
      } catch (_) {/* Reconcile the retained material below. */}
    }
    final owner = await _signal.keyOwner();
    if (owner != null && owner != ownerUserId) {
      throw const KeyRecoveryRequired(
          'Encryption keys belong to another account; manual recovery is required');
    }
    final existed = await _signal.hasKeys();
    final legacy = existed && owner == null;
    if (!legacy) await _signal.setKeyOwner(ownerUserId);
    var bundle = existed ? await _signal.currentPublicBundle() : null;
    if (!legacy && await _signal.prekeyRecoveryPending()) {
      bundle = await _signal.resumeInitialKeys(otpkCount: otpkCount);
    }
    if (bundle == null) {
      if (legacy) {
        throw const KeyRecoveryRequired(
            'Incomplete legacy encryption keys require manual recovery');
      }
      bundle = await _signal.resumeInitialKeys(otpkCount: otpkCount);
    }
    Future<void> upload(PublicKeyBundle value) => _api.uploadDeviceKeys({
          ...value.toJson(),
          'owner_user_id': ownerUserId,
          'existing_only': legacy,
        });
    try {
      await upload(bundle);
    } on DioException catch (error) {
      final data = error.response?.data;
      if (!legacy &&
          error.response?.statusCode == 409 &&
          data is Map &&
          data['code'] == 'key_prekey_conflict') {
        final bounds = await _api.prekeyAllocation({
          'owner_user_id': ownerUserId,
          'identity_key_pub': bundle.toJson()['identity_key_pub'],
          'signed_prekey': bundle.toJson()['signed_prekey'],
        });
        await _signal.preparePrekeyRecovery(
            bounds.oneTimeFloor, bounds.kyberFloor);
        _work.pending = null; // Private records remain in secure storage.
        bundle = await _signal.resumeInitialKeys(otpkCount: otpkCount);
        await upload(bundle);
      } else if (!legacy &&
          error.response?.statusCode == 400 &&
          data is Map &&
          data['code'] == 'key_bundle_incomplete') {
        bundle = await _signal.resumeInitialKeys(otpkCount: otpkCount);
        await upload(bundle);
      } else {
        rethrow;
      }
    }
    await _signal.setKeyOwner(ownerUserId);
    await _signal.completePrekeyRecovery();
    _work.pending = null; // The full saved bundle was reconciled.
    return !existed;
  }

  /// Only called after the person accepts the device-change warning. The
  /// saved owner and private identity must already belong to this account.
  Future<void> requestMessagingRecovery({required String ownerUserId}) =>
      _withRecovery(() async {
        final epoch = _work.recoveryEpoch;
        try {
          await _work.initialization;
        } catch (_) {}
        try {
          await _work.replenishment;
        } catch (_) {}
        if (await _signal.keyOwner() != ownerUserId) {
          throw const KeyRecoveryRequired(
              'Saved keys must belong to this account before moving messaging');
        }
        var bundle = await _signal.currentPublicBundle();
        if (bundle == null) {
          throw const KeyRecoveryRequired('Saved keys are incomplete');
        }
        if (bundle.kyberPreKeys.isEmpty) {
          bundle = await _signal.resumeInitialKeys();
        }
        if (epoch != _work.recoveryEpoch) return;
        final body = {...bundle.toJson(), 'owner_user_id': ownerUserId};
        final ticket = await _api.requestMessagingRecovery(body);
        if (epoch != _work.recoveryEpoch) return;
        _work.confirmation = (owner: ownerUserId, bundle: body, ticket: ticket);
      });

  Future<void> confirmMessagingRecovery(
          {required String ownerUserId, required String code}) =>
      _withRecovery(() async {
        final pending = _work.confirmation;
        if (pending == null ||
            pending.owner != ownerUserId ||
            await _signal.keyOwner() != ownerUserId) {
          throw const KeyRecoveryRequired('Request a new confirmation code');
        }
        await _api.confirmMessagingRecovery(pending.bundle,
            ticket: pending.ticket, code: code);
        // No regeneration or wipe, even after an interrupted response. Leave
        // the ticket available on failure so an exact retry is idempotent.
        await _signal.completePrekeyRecovery();
        _work.pending = null;
        _work.confirmation = null;
      });

  void cancelMessagingRecovery() {
    _work.recoveryEpoch++;
    _work.confirmation = null;
  }

  Future<void> _withRecovery(Future<void> Function() action) {
    if (_work.reset != null || _work.recovery != null) {
      return Future.error(StateError('Messaging setup is busy'));
    }
    late final Future<void> operation;
    operation = action().whenComplete(() {
      if (identical(_work.recovery, operation)) _work.recovery = null;
    });
    _work.recovery = operation;
    return operation;
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
  }) {
    if (_work.reset != null ||
        _work.recovery != null ||
        _work.confirmation != null) {
      return Future.error(StateError('Encryption setup is stopping'));
    }
    final pending = _work.replenishment;
    if (pending != null) return pending;
    late final Future<({int otpks, int kyber})> operation;
    operation =
        _replenish(otpkThreshold, otpkBatchSize, kyberThreshold, kyberBatchSize)
            .whenComplete(() {
      if (identical(_work.replenishment, operation)) _work.replenishment = null;
    });
    _work.replenishment = operation;
    return operation;
  }

  Future<({int otpks, int kyber})> _replenish(int otpkThreshold,
      int otpkBatchSize, int kyberThreshold, int kyberBatchSize) async {
    final initialization = _work.initialization;
    if (initialization != null) await initialization;
    final owner = await _signal.keyOwner();
    final bundle = await _signal.currentPublicBundle();
    if (owner == null || bundle == null) {
      throw const KeyRecoveryRequired(
          'Encryption keys must be registered before replenishment');
    }
    final freshOtpks = _work.pending?.otpks ??
        await _signal.replenishOneTimePreKeys(
          threshold: otpkThreshold,
          batchSize: otpkBatchSize,
        );
    // Preserve the completed first batch before generating the second pool.
    // Its private records already count toward the local inventory threshold.
    _work.pending = (otpks: freshOtpks, kyber: _work.pending?.kyber);
    final freshKyber = _work.pending?.kyber ??
        await _signal.replenishKyberPreKeys(
          threshold: kyberThreshold,
          batchSize: kyberBatchSize,
        );
    if (freshOtpks.isEmpty && freshKyber.isEmpty) {
      _work.pending = null;
      return (otpks: 0, kyber: 0);
    }

    _work.pending = (otpks: freshOtpks, kyber: freshKyber);
    await _api.replenishPreKeys(
      ownerUserId: owner,
      identityKey: base64.encode(bundle.identityPublic),
      oneTimePreKeys: freshOtpks.map((k) => k.toJson()).toList(growable: false),
      kyberPreKeys: freshKyber.map((k) => k.toJson()).toList(growable: false),
    );
    _work.pending = null;
    return (otpks: freshOtpks.length, kyber: freshKyber.length);
  }

  /// Generates a fresh signed prekey, persists, and uploads. Called
  /// by the weekly rotation scheduler (Phase 2).
  Future<void> rotateSignedPreKey() async {
    if (_work.reset != null ||
        _work.recovery != null ||
        _work.confirmation != null) {
      throw StateError('Messaging setup is busy');
    }
    final newSpk = await _signal.rotateSignedPreKey();
    await _api.rotateSignedPreKey(newSpk.toJson());
  }

  /// Sign-out cleanup: revoke on server + wipe locally. Safe to call
  /// even if no keys exist (the server side is idempotent).
  Future<void> resetKeys() {
    final pending = _work.reset;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _resetKeys().whenComplete(() {
      if (identical(_work.reset, operation)) _work.reset = null;
    });
    _work.reset = operation;
    return operation;
  }

  Future<void> _resetKeys() async {
    // Drain already-started writes before revocation, and block new work while
    // resetting. A late upload must not run after deliberate sign-out cleanup.
    try {
      await _work.initialization;
    } catch (_) {}
    try {
      await _work.replenishment;
    } catch (_) {}
    try {
      await _work.recovery;
    } catch (_) {}
    cancelMessagingRecovery();
    // Server first so any stale keys are neutralized even if local
    // wipe somehow fails partway. Always wipe local keys on a deliberate
    // sign-out even if the best-effort server revocation cannot complete.
    try {
      await _api.revokeDeviceKeys();
    } finally {
      await _signal.wipeKeys();
      _work.pending = null;
    }
  }

  /// Fetches a peer's bundle for session setup. Thin passthrough,
  /// exposed here so crypto-path callers only ever talk to this
  /// class rather than reaching into ApiService directly.
  Future<Map<String, dynamic>> fetchPeerKeyBundle(String userId) {
    return _api.getUserKeyBundle(userId);
  }
}
