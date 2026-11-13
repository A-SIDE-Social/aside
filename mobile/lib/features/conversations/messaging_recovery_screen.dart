import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';

/// An explicit device change, not a retry or a backup restoration.
class MessagingRecoveryScreen extends ConsumerStatefulWidget {
  const MessagingRecoveryScreen({super.key});

  @override
  ConsumerState<MessagingRecoveryScreen> createState() =>
      _MessagingRecoveryScreenState();
}

class _MessagingRecoveryScreenState
    extends ConsumerState<MessagingRecoveryScreen> {
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;
  late final AuthNotifier _auth;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(authProvider.notifier);
  }

  @override
  void dispose() {
    _auth.cancelMessagingRecovery();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_sent) {
        await _auth.confirmMessagingRecovery(_code.text.trim());
        if (mounted) Navigator.of(context).pop(true);
      } else {
        await _auth.requestMessagingRecovery();
        if (mounted) setState(() => _sent = true);
      }
    } catch (error) {
      if (!mounted) return;
      // Only fixed user-facing copy; never interpolate request/key material.
      final data = error is DioException ? error.response?.data : null;
      setState(() => _error = switch (data is Map ? data['code'] : null) {
            'otp_invalid' =>
              'That code is incorrect or expired. Check your email and try again.',
            'otp_attempt_limit' =>
              'Too many attempts. Go back and request a new code.',
            'otp_cooldown' =>
              'Please wait a little before requesting another code.',
            'key_recovery_required' =>
              'Messaging setup changed. Go back and request a new code.',
            _ =>
              'Couldn’t finish messaging setup. Your saved keys are safe. Check your connection and try again.',
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Move messaging')),
          body: SafeArea(
              child: ListView(padding: const EdgeInsets.all(24), children: [
            Text('Use messaging on this device?',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            const Text(
                'This replaces the encryption registration for your other device. Only continue if you want to use messaging here.'),
            const SizedBox(height: 12),
            const Text(
                'Your private keys on this device will be kept. Older encrypted messages may not be readable here: this does not transfer message history or erase copies saved on another device.'),
            const SizedBox(height: 12),
            const Text(
                'We’ll ask for a code sent to your account’s email address before changing anything.'),
            const SizedBox(height: 12),
            const Text(
                'Your contacts may need to update A/SIDE to exchange new messages after this change.'),
            if (_sent) ...[
              const SizedBox(height: 24),
              const Text('Check your account’s email for a six-digit code.'),
              TextField(
                  controller: _code,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6)
                  ],
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(labelText: 'Email code'),
                  onChanged: (_) => setState(() {})),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, semanticsLabel: _error)
            ],
            const SizedBox(height: 24),
            FilledButton(
                onPressed: _busy || (_sent && _code.text.trim().length != 6)
                    ? null
                    : _submit,
                child: Text(_busy
                    ? 'Please wait…'
                    : _sent
                        ? 'Confirm device change'
                        : 'Email me a code')),
            TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
          ])),
        ),
      );
}
