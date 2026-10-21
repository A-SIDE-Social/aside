import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pin_code_fields/pin_code_fields.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/constants.dart';
import '../../core/config/env.dart';
import '../../core/network/api_client.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

enum _Step { email, otp, register }

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  _Step _step = _Step.email;
  bool _loading = false;
  String? _error;
  String _otpCode = '';
  String? _codeEmail;
  final _codeController = TextEditingController();
  final Map<String, int> _resendAfterTick = {};
  late final Timer _cooldownTimer;
  int _authAfterTick = 0;

  String get _email => _emailController.text.trim().toLowerCase();
  int get _resendSeconds =>
      ((_resendAfterTick[_email] ?? 0) - _cooldownTimer.tick).clamp(0, 900);
  int get _authSeconds => (_authAfterTick - _cooldownTimer.tick).clamp(0, 900);
  int get _requestWait =>
      _resendSeconds > _authSeconds ? _resendSeconds : _authSeconds;

  @override
  void initState() {
    super.initState();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_resendAfterTick.isNotEmpty || _authAfterTick > 0)) {
        setState(() {
          _resendAfterTick
              .removeWhere((_, tick) => tick <= _cooldownTimer.tick);
          if (_authAfterTick <= _cooldownTimer.tick) _authAfterTick = 0;
        });
      }
    });
  }

  void _waitToResend(int seconds) {
    final tick = _cooldownTimer.tick + seconds.clamp(1, 900);
    if (tick > (_resendAfterTick[_email] ?? 0)) {
      _resendAfterTick[_email] = tick;
    }
  }

  String? _errorCode(Object error) {
    final data = error is DioException ? error.response?.data : null;
    if (data is! Map) return null;
    if (data['code'] is String) return data['code'] as String;
    // Older servers return these fixed messages without a code. A resend
    // cooldown must still leave an already delivered code usable.
    return switch (data['error']) {
      'Please wait before requesting another code' => 'otp_cooldown',
      'Too many attempts. Please request a new code.' => 'otp_attempt_limit',
      _ => null,
    };
  }

  int _retrySeconds(Object error) {
    if (error is! DioException) return 30;
    final data = error.response?.data;
    final body = data is Map ? data['retry_after_seconds'] : null;
    final header = error.response?.headers.value('retry-after');
    final value = body is num ? body.toInt() : int.tryParse(header ?? '');
    return (value ?? 30).clamp(1, 900);
  }

  void _rememberRateLimit(Object error) {
    if (error is! DioException || error.response?.statusCode != 429) return;
    final code = _errorCode(error);
    if (code == 'otp_attempt_limit') return;
    if (code == 'otp_cooldown') {
      _waitToResend(_retrySeconds(error));
    } else {
      _authAfterTick = _cooldownTimer.tick + _retrySeconds(error);
    }
  }

  bool _deliveryUncertain(Object error) {
    if (_errorCode(error) == 'otp_delivery_uncertain') return true;
    if (_errorCode(error) == 'otp_delivery_failed') return false;
    return error is DioException &&
        (error.type == DioExceptionType.receiveTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.connectionError ||
            error.response?.statusCode == 503);
  }

  void _openCodeEntry() {
    setState(() {
      if (_codeEmail != _email) {
        _codeController.clear();
        _otpCode = '';
      }
      _codeEmail = _email;
      _step = _Step.otp;
      _error = null;
    });
  }

  final _emailController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _inviteCodeController = TextEditingController();

  @override
  void dispose() {
    _cooldownTimer.cancel();
    _codeController.dispose();
    _emailController.dispose();
    _displayNameController.dispose();
    _inviteCodeController.dispose();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    final email = _email;
    if (_loading || email.isEmpty || _requestWait > 0) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await ref.read(authProvider.notifier).requestOtp(email);
      if (!mounted) return;
      setState(() {
        _waitToResend(30);
        _codeEmail = email;
        _codeController.clear();
        _otpCode = '';
        _step = _Step.otp;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _rememberRateLimit(e);
        if (_errorCode(e) == 'otp_delivery_failed') {
          _waitToResend(_retrySeconds(e));
        }
        if (_deliveryUncertain(e)) {
          _waitToResend(_retrySeconds(e));
          _codeEmail = email;
          _codeController.clear();
          _otpCode = '';
          _step = _Step.otp;
          _error =
              'We couldn’t confirm delivery. If a code arrives, enter it here. '
              'Wait before requesting another.';
        } else {
          _error = _extractMessage(e);
        }
      });
    }
  }

  Future<void> _verifyOtp(String code) async {
    if (_loading ||
        _step != _Step.otp ||
        _codeEmail != _email ||
        code != _codeController.text ||
        _authSeconds > 0 ||
        code.length != 6) {
      return;
    }
    _otpCode = code;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final email = _emailController.text.trim();
      await ref.read(authProvider.notifier).verifyOtp(email, code);
      // If successful, the router will redirect to home.
    } catch (e) {
      if (!mounted) return;
      // Backend returns 400 with "required for registration" when user doesn't exist yet.
      if (_isRegistrationRequired(e)) {
        setState(() {
          _step = _Step.register;
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
          _rememberRateLimit(e);
          _error = _extractMessage(e);
        });
      }
    }
  }

  Future<void> _register() async {
    final displayName = _displayNameController.text.trim();
    final inviteCode = _inviteCodeController.text.trim();

    if (_loading || _authSeconds > 0 || displayName.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final email = _emailController.text.trim();
      // Re-send the same OTP code with registration data.
      // The backend preserves the OTP when display_name is missing,
      // so the same code works for the registration retry.
      await ref.read(authProvider.notifier).verifyOtp(
            email,
            _otpCode,
            displayName: displayName,
            inviteCode: inviteCode.isNotEmpty ? inviteCode : null,
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _rememberRateLimit(e);
        _error = _extractMessage(e);
        if (['otp_invalid', 'otp_attempt_limit'].contains(_errorCode(e))) {
          _step = _Step.otp;
        }
      });
    }
  }

  bool _isRegistrationRequired(Object e) {
    if (_errorCode(e) == 'registration_required') return true;
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        return (data['error'] as String).contains('required for registration');
      }
    }
    return false;
  }

  String _extractMessage(Object e) {
    if (e is ApiException) return e.message;
    if (e is DioException) return ApiException.fromDioException(e).message;
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _loading
              ? const LoadingIndicator(message: 'Please wait...')
              : switch (_step) {
                  _Step.email =>
                    _scrollableStep(_buildEmailStep(theme, colors)),
                  _Step.otp => _scrollableStep(_buildOtpStep(theme, colors)),
                  _Step.register => _buildRegisterStep(theme, colors),
                },
        ),
      ),
    );
  }

  Widget _scrollableStep(Widget child) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(child: child),
          ),
        ),
      );

  Widget _buildError(AppColorTokens colors) {
    if (_error == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.error.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      child: Text(
        _error!,
        style: TextStyle(
          fontSize: 14,
          color: AppColors.error,
        ),
      ),
    );
  }

  Widget _buildEmailStep(ThemeData theme, AppColorTokens colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(flex: 3),
        // Brand block — logo mark + wordmark + italic-serif tagline.
        // Same logo used on the marketing site and in launch emails;
        // tagline uses the iOS / Android native serif fallback chain
        // (the email template uses the same family stack) so the
        // brand voice carries across email → app without bundling a
        // web font.
        Center(
          child: Column(
            children: [
              Image.asset(
                'assets/images/logo_mark.png',
                width: 64,
                height: 64,
                filterQuality: FilterQuality.high,
              ),
              const SizedBox(height: 20),
              Text(
                Env.appName,
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'Your private social circle',
                style: TextStyle(
                  fontFamily: 'Iowan Old Style',
                  fontFamilyFallback: const [
                    'Palatino',
                    'Georgia',
                    'Noto Serif',
                    'serif',
                  ],
                  fontStyle: FontStyle.italic,
                  fontSize: 17,
                  height: 1.3,
                  color: colors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 48),
        _buildError(colors),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'Email address',
          ),
          onSubmitted: (_) => _requestOtp(),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _requestWait == 0 ? _requestOtp : null,
          child: Text(
              _requestWait > 0 ? 'Send code in ${_requestWait}s' : 'Continue'),
        ),
        Center(
          child: TextButton(
            onPressed: _email.isEmpty ? null : _openCodeEntry,
            child: const Text('I have a code'),
          ),
        ),
        const SizedBox(height: 16),
        Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 12, color: colors.textTertiary),
            children: [
              const TextSpan(text: 'By continuing, you agree to our '),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: () => InAppBrowser.open(
                    context,
                    Env.termsUrl,
                    title: 'Terms of Service',
                  ),
                  child: Text(
                    'Terms',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textTertiary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              const TextSpan(text: ' and '),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: () => InAppBrowser.open(
                    context,
                    Env.privacyUrl,
                    title: 'Privacy Policy',
                  ),
                  child: Text(
                    'Privacy Policy',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textTertiary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              const TextSpan(text: '.'),
            ],
          ),
          textAlign: TextAlign.center,
        ),
        const Spacer(flex: 3),
      ],
    );
  }

  Widget _buildOtpStep(ThemeData theme, AppColorTokens colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(flex: 2),
        Text('Enter code', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 8),
        Text(
          'Enter the code for ${_emailController.text.trim()}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 48),
        _buildError(colors),
        PinCodeTextField(
          appContext: context,
          controller: _codeController,
          autoDisposeControllers: false,
          length: 6,
          keyboardType: TextInputType.number,
          animationType: AnimationType.fade,
          autoFocus: true,
          cursorColor: colors.textPrimary,
          textStyle: theme.textTheme.titleLarge,
          pinTheme: PinTheme(
            shape: PinCodeFieldShape.box,
            borderRadius: BorderRadius.circular(14),
            fieldHeight: 56,
            fieldWidth: 48,
            activeFillColor: colors.surfaceAlt,
            inactiveFillColor: colors.surfaceAlt,
            selectedFillColor: colors.surfaceAlt,
            activeColor: colors.textTertiary,
            inactiveColor: colors.border,
            selectedColor: colors.textPrimary,
            borderWidth: 0.5,
          ),
          enableActiveFill: true,
          onCompleted: _verifyOtp,
          onChanged: (code) => setState(() => _otpCode = code),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _otpCode.length == 6 && _authSeconds == 0
              ? () => _verifyOtp(_otpCode)
              : null,
          child: Text(_authSeconds > 0
              ? 'Try again in ${_authSeconds}s'
              : 'Verify code'),
        ),
        Center(
          child: TextButton(
            onPressed: _requestWait == 0 ? _requestOtp : null,
            child: Text(_requestWait > 0
                ? 'Resend code in ${_requestWait}s'
                : 'Send another code'),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: () {
              setState(() {
                _step = _Step.email;
                _error = null;
              });
            },
            child: Text(
              'Use a different email',
              style: TextStyle(color: colors.textTertiary),
            ),
          ),
        ),
        const Spacer(flex: 3),
      ],
    );
  }

  Widget _buildRegisterStep(ThemeData theme, AppColorTokens colors) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.12),
          Text('Welcome to ${Env.appName}',
              style: theme.textTheme.headlineLarge),
          const SizedBox(height: 8),
          Text(
            'Create your account to get started',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 48),
          _buildError(colors),
          TextField(
            controller: _displayNameController,
            decoration: const InputDecoration(hintText: 'Your name'),
            maxLength: AppLimits.maxDisplayNameLength,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _inviteCodeController,
            decoration: const InputDecoration(
              hintText: 'Invite link or code (optional)',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _register(),
          ),
          const SizedBox(height: 4),
          Text(
            // Field still accepts a URL, bare slug, OR a legacy
            // alphanumeric code on the server side — kept for
            // backwards-compat. The hint just says "link" now to
            // align with how new shares actually happen.
            'Paste a friend’s invite link or enter their code. You can also add friends after signup.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _authSeconds == 0 ? _register : null,
            child: Text(_authSeconds > 0
                ? 'Try again in ${_authSeconds}s'
                : 'Create Account'),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: _openCodeEntry,
              child: const Text('Back to code'),
            ),
          ),
          Center(
            child: TextButton(
              onPressed: () {
                setState(() {
                  _otpCode = '';
                  _step = _Step.email;
                  _error = null;
                });
              },
              child: Text(
                'Start over',
                style: TextStyle(color: colors.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
