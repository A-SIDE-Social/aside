import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../src/rust/api/identity.dart';
import '../../src/rust/frb_generated.dart';

/// Phase 1a spike screen. Runs three FFI calls into the Rust crypto
/// crate and shows the results, proving the flutter_rust_bridge +
/// cross-compile pipeline works end-to-end. Reachable at
/// `/debug/e2ee`. Remove this screen once Phase 1b lands.
class E2eeSpikeScreen extends StatefulWidget {
  const E2eeSpikeScreen({super.key});

  @override
  State<E2eeSpikeScreen> createState() => _E2eeSpikeScreenState();
}

class _E2eeSpikeScreenState extends State<E2eeSpikeScreen> {
  late final Future<void> _initFuture = RustLib.init();
  String? _version;
  IdentityKeypair? _keypair;
  Uint8List? _roundtripPublic;
  bool? _roundtripOk;
  Object? _error;

  Future<void> _run() async {
    setState(() {
      _error = null;
      _version = null;
      _keypair = null;
      _roundtripPublic = null;
      _roundtripOk = null;
    });
    try {
      final version = cryptoVersion();
      final kp = generateIdentityKeypair();
      final rt = identityPublicFromSerialized(serialized: kp.serialized);
      final ok = listEquals(rt, kp.publicKey);
      setState(() {
        _version = version;
        _keypair = kp;
        _roundtripPublic = rt;
        _roundtripOk = ok;
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('E2EE Phase 1a spike')),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText(
                  'RustLib.init() failed: ${snap.error}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Tap the button to generate an Ed25519 identity keypair '
                'in Rust, then re-derive the public key from the private '
                'seed and confirm they match.',
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _run,
                child: const Text('Generate + round-trip'),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                SelectableText(
                  'Error: $_error',
                  style: const TextStyle(color: Colors.red),
                ),
              if (_version != null) _row('crypto_version()', _version!),
              if (_keypair != null) ...[
                _row('public_key (hex, 33 bytes)', _hex(_keypair!.publicKey)),
                _row('serialized (hex, protobuf)', _hex(_keypair!.serialized)),
              ],
              if (_roundtripPublic != null)
                _row('roundtrip public_key (hex)', _hex(_roundtripPublic!)),
              if (_roundtripOk != null)
                _row(
                  'roundtrip match',
                  _roundtripOk! ? 'TRUE ✓' : 'FALSE ✗',
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
          ),
        ],
      ),
    );
  }
}
