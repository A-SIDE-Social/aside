// Riverpod wiring for the E2EE crypto client. Providers are kept
// thin — logic lives in [SignalClient] / [SecureKeyStorage]. These
// are just dependency-injection points so integration tests and the
// debug screen can swap the storage backend.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crypto/key_registry_sync.dart';
import '../core/crypto/key_storage.dart';
import '../core/crypto/signal_client.dart';
import 'api_provider.dart';

/// Secure storage backend. Production returns [SecureKeyStorage];
/// override in tests with an in-memory fake.
final keyStorageProvider = Provider<KeyStorage>((ref) {
  return SecureKeyStorage();
});

/// Top-level crypto client. Singleton — the client is stateless aside
/// from the internal "ffi loaded" flag, which is idempotent anyway.
final signalClientProvider = Provider<SignalClient>((ref) {
  return SignalClient(ref.read(keyStorageProvider));
});

/// Orchestrates local crypto state + server key registry. This is the
/// layer callers (sign-in flow, sign-out handler, background
/// replenishment task) should talk to — SignalClient and ApiService
/// are the underlying primitives.
final keyRegistrySyncProvider = Provider<KeyRegistrySync>((ref) {
  return KeyRegistrySync(
    ref.read(signalClientProvider),
    ref.read(apiServiceProvider),
  );
});
