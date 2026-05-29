import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pin_code_fields/pin_code_fields.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_colors.dart';
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

  final _emailController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _inviteCodeController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _displayNameController.dispose();
    _inviteCodeController.dispose();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await ref.read(authProvider.notifier).requestOtp(email);
      if (!mounted) return;
      setState(() {
        _step = _Step.otp;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _extractMessage(e);
      });
    }
  }

  Future<void> _verifyOtp(String code) async {
    if (code.length != 6) return;
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
          _error = _extractMessage(e);
        });
      }
    }
  }

  Future<void> _register() async {
    final displayName = _displayNameController.text.trim();
    final inviteCode = _inviteCodeController.text.trim();

    if (displayName.isEmpty) return;

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
      // New registration succeeded — flag the welcome sheet for the feed
      // screen to pick up, then go to contact sync onboarding.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pending_welcome_sheet', true);
      if (mounted) {
        context.go('/onboarding/contacts');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _extractMessage(e);
      });
    }
  }

  bool _isRegistrationRequired(Object e) {
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
                  _Step.email => _buildEmailStep(theme, colors),
                  _Step.otp => _buildOtpStep(theme, colors),
                  _Step.register => _buildRegisterStep(theme, colors),
                },
        ),
      ),
    );
  }

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
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _requestOtp,
          child: const Text('Continue'),
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
          'We sent a code to ${_emailController.text.trim()}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 48),
        _buildError(colors),
        PinCodeTextField(
          appContext: context,
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
          onChanged: (_) {},
        ),
        const SizedBox(height: 16),
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
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _inviteCodeController,
            decoration: const InputDecoration(
              hintText: 'Invite link (optional)',
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
            'Paste the invite link a friend shared with you.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _register,
            child: const Text('Create Account'),
          ),
          const SizedBox(height: 16),
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
