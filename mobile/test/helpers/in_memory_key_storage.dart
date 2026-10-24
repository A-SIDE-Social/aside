import 'dart:typed_data';
import 'package:aside/core/crypto/key_storage.dart';
import 'package:aside/src/rust/api/identity.dart';
import 'package:aside/src/rust/api/prekeys.dart';

/// In-memory [KeyStorage]. Allows two SignalClient instances to
/// coexist in the same test process without clobbering platform
/// secure storage.
class InMemoryKeyStorage implements KeyStorage {
  PrekeyRecoveryState? _recovery;
  @override
  Future<PrekeyRecoveryState?> loadPrekeyRecovery() async => _recovery;
  @override
  Future<void> savePrekeyRecovery(PrekeyRecoveryState state) async {
    _recovery = state;
  }

  @override
  Future<int> reserveOneTimePreKeyIds(int count,
      {int minimumLastId = 0}) async {
    if (_lastOtpk < minimumLastId) _lastOtpk = minimumLastId;
    final start = _lastOtpk + 1;
    _lastOtpk += count;
    return start;
  }

  @override
  Future<int> reserveKyberPreKeyIds(int count, {int minimumLastId = 0}) async {
    if (_lastKyber < minimumLastId) _lastKyber = minimumLastId;
    final start = _lastKyber + 1;
    _lastKyber += count;
    return start;
  }

  int _lastOtpk = 0;
  int _lastKyber = 0;
  @override
  Future<int> lastOneTimePreKeyId() async => _lastOtpk;
  @override
  Future<int> lastKyberPreKeyId() async => _lastKyber;
  String? _owner;
  @override
  Future<String?> loadOwner() async => _owner;
  @override
  Future<void> saveOwner(String userId) async {
    _owner = userId;
  }

  IdentityKeypair? _identity;
  SignedPreKey? _signedPreKey;
  final Map<int, OneTimePreKey> _otpks = {};
  final Map<int, KyberPreKey> _kpks = {};
  final Map<String, Uint8List> _sessions = {};

  @override
  Future<void> saveIdentityKeyPair(IdentityKeypair kp) async {
    _identity = kp;
  }

  @override
  Future<IdentityKeypair?> loadIdentityKeyPair() async => _identity;

  @override
  Future<void> saveSignedPreKey(SignedPreKey spk) async {
    _signedPreKey = spk;
  }

  @override
  Future<SignedPreKey?> loadSignedPreKey() async => _signedPreKey;

  @override
  Future<void> saveOneTimePreKey(OneTimePreKey otpk) async {
    if (otpk.id > _lastOtpk) _lastOtpk = otpk.id;
    _otpks[otpk.id] = otpk;
  }

  @override
  Future<OneTimePreKey?> loadOneTimePreKey(int id) async => _otpks[id];

  @override
  Future<void> deleteOneTimePreKey(int id) async {
    _otpks.remove(id);
  }

  @override
  Future<List<int>> listOneTimePreKeyIds() async =>
      _otpks.keys.toList()..sort();

  @override
  Future<void> saveKyberPreKey(KyberPreKey kpk) async {
    if (kpk.id > _lastKyber) _lastKyber = kpk.id;
    _kpks[kpk.id] = kpk;
  }

  @override
  Future<KyberPreKey?> loadKyberPreKey(int id) async => _kpks[id];

  @override
  Future<void> deleteKyberPreKey(int id) async {
    _kpks.remove(id);
  }

  @override
  Future<List<int>> listKyberPreKeyIds() async => _kpks.keys.toList()..sort();

  @override
  Future<void> saveSession(
    String peerUserId,
    Uint8List sessionSerialized,
  ) async {
    _sessions[peerUserId] = sessionSerialized;
  }

  @override
  Future<Uint8List?> loadSession(String peerUserId) async =>
      _sessions[peerUserId];

  @override
  Future<void> deleteSession(String peerUserId) async {
    _sessions.remove(peerUserId);
  }

  @override
  Future<List<String>> listSessionPeerIds() async =>
      _sessions.keys.toList()..sort();

  final Map<String, String> _plaintexts = {};
  final Map<String, PeerIdentityInfo> _peerIdentities = {};
  // Phase 1f: sender-key records, keyed by "<conversationId>:<senderUserId>".
  final Map<String, Uint8List> _senderKeys = {};

  @override
  Future<void> savePlaintext(String messageId, String plaintext) async {
    _plaintexts[messageId] = plaintext;
  }

  @override
  Future<String?> loadPlaintext(String messageId) async =>
      _plaintexts[messageId];

  @override
  Future<void> savePeerIdentityInfo(
    String peerUserId,
    PeerIdentityInfo info,
  ) async {
    _peerIdentities[peerUserId] = info;
  }

  @override
  Future<PeerIdentityInfo?> loadPeerIdentityInfo(String peerUserId) async =>
      _peerIdentities[peerUserId];

  String _sk(String convId, String senderId) => '$convId:$senderId';

  @override
  Future<void> saveSenderKey(
    String conversationId,
    String senderUserId,
    Uint8List recordSerialized,
  ) async {
    _senderKeys[_sk(conversationId, senderUserId)] = recordSerialized;
  }

  @override
  Future<Uint8List?> loadSenderKey(
    String conversationId,
    String senderUserId,
  ) async =>
      _senderKeys[_sk(conversationId, senderUserId)];

  @override
  Future<void> deleteSenderKey(
    String conversationId,
    String senderUserId,
  ) async {
    _senderKeys.remove(_sk(conversationId, senderUserId));
  }

  @override
  Future<List<String>> listSenderKeyContributors(String conversationId) async {
    final prefix = '$conversationId:';
    return _senderKeys.keys
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .toList()
      ..sort();
  }

  @override
  Future<void> deleteAllSenderKeysFor(String conversationId) async {
    final prefix = '$conversationId:';
    _senderKeys.removeWhere((k, _) => k.startsWith(prefix));
  }

  final Map<String, int> _senderKeyEpochs = {};

  @override
  Future<void> saveOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
    int epoch,
  ) async {
    _senderKeyEpochs['$conversationId:$ownUserId'] = epoch;
  }

  @override
  Future<int?> loadOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
  ) async =>
      _senderKeyEpochs['$conversationId:$ownUserId'];

  @override
  Future<void> wipe() async {
    _lastOtpk = 0;
    _lastKyber = 0;
    _recovery = null;
    _owner = null;
    _identity = null;
    _signedPreKey = null;
    _otpks.clear();
    _kpks.clear();
    _sessions.clear();
    _plaintexts.clear();
    _peerIdentities.clear();
    _senderKeys.clear();
    _senderKeyEpochs.clear();
  }
}

/// Builds a [PeerKeyBundle] from a freshly-generated [PublicKeyBundle]
/// — simulates fetching the bundle from `GET /v1/users/:id/keybundle`,
/// which would atomically pick one OTPK and one Kyber prekey.
