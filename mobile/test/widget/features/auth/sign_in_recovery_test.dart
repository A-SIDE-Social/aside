import 'package:aside/features/auth/sign_in_screen.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Auth extends AuthNotifier {
  Object? requestError;
  Object? verifyError;
  final requests = <String>[];
  final verifications = <({String email, String code, String? name})>[];

  @override
  AuthState build() => const AuthState(status: AuthStatus.unauthenticated);

  @override
  Future<void> requestOtp(String email) async {
    requests.add(email);
    if (requestError != null) throw requestError!;
  }

  @override
  Future<void> verifyOtp(String email, String code,
      {String? inviteCode, String? displayName}) async {
    verifications.add((email: email, code: code, name: displayName));
    if (verifyError != null) throw verifyError!;
    state = const AuthState(status: AuthStatus.authenticated);
  }
}

DioException _failure(int status, String code, {int? seconds}) {
  final request = RequestOptions(path: '/v1/auth/request-otp');
  return DioException(
    requestOptions: request,
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: request,
      statusCode: status,
      data: {
        'error': 'Please try again.',
        'code': code,
        if (seconds != null) 'retry_after_seconds': seconds,
      },
    ),
  );
}

void main() {
  late _Auth auth;
  setUp(() => auth = _Auth());

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [authProvider.overrideWith(() => auth)],
      child: const MaterialApp(home: SignInScreen()),
    ));
    await tester.enterText(find.byType(TextField).first, 'person@example.com');
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
  }

  for (final error in [
    DioException(
      requestOptions: RequestOptions(path: '/v1/auth/request-otp'),
      type: DioExceptionType.receiveTimeout,
    ),
    _failure(503, 'otp_delivery_uncertain', seconds: 30),
  ]) {
    testWidgets(
        'uncertain delivery allows code entry without an automatic resend: ${error.type}',
        (tester) async {
      auth.requestError = error;
      await open(tester);
      expect(find.text('Enter code'), findsOneWidget);
      expect(
          find.textContaining('We couldn’t confirm delivery'), findsOneWidget);
      expect(find.text('Resend code in 30s'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(auth.requests, hasLength(1));
      expect(auth.verifications.single.code, '123456');
      await finish(tester);
    });
  }

  testWidgets(
      'same-address back navigation keeps cooldown; changing address sends once',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('Use a different email'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Send code in 30s'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField).first, ' PERSON@example.com ');
    await tester.pump();
    expect(find.text('Send code in 30s'), findsOneWidget);
    await tester.tap(find.text('I have a code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Send another code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.requests, ['person@example.com', 'person@example.com']);
    await tester.tap(find.text('Use a different email'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(
        find.byType(TextField).first, 'different@example.com');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.requests.last, 'different@example.com');
    await finish(tester);
  });

  testWidgets(
      'verification failure retains the entered code and offers an explicit retry',
      (tester) async {
    auth.verifyError = _failure(503, 'temporary_failure');
    await open(tester);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications, hasLength(1));
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '123456');
    auth.verifyError = null;
    await tester.tap(find.text('Verify code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications, hasLength(2));
    expect(auth.requests, hasLength(1));
    await finish(tester);
  });

  testWidgets(
      'shared auth budget blocks verification but resend cooldown does not',
      (tester) async {
    auth.requestError = _failure(429, 'auth_rate_limited', seconds: 45);
    await open(tester);
    await tester.tap(find.text('I have a code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications, isEmpty);
    expect(find.textContaining('Try again in '), findsOneWidget);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);
    await tester.pump(const Duration(seconds: 46));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Verify code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications, hasLength(1));
    await finish(tester);
  });

  testWidgets(
      'definite delivery rejection stays at email and can use an existing code',
      (tester) async {
    auth.requestError = _failure(503, 'otp_delivery_failed', seconds: 30);
    await open(tester);
    expect(find.text('Enter code'), findsNothing);
    await tester.tap(find.text('I have a code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Enter code'), findsOneWidget);
    expect(auth.requests, hasLength(1));
    await finish(tester);
  });

  testWidgets(
      'registration correction reuses the code and exhausted code can be replaced',
      (tester) async {
    auth.verifyError = _failure(400, 'registration_required');
    await open(tester);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(
        find.widgetWithText(TextField, 'Your name'), 'My name');
    auth.verifyError = _failure(400, 'invalid_name');
    await tester.tap(find.text('Create Account'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications.last.code, '123456');
    expect(auth.verifications.last.name, 'My name');
    auth.verifyError = _failure(429, 'otp_attempt_limit');
    await tester.tap(find.text('Create Account'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Enter code'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Send another code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.requests, hasLength(2));
    await finish(tester);
  });

  testWidgets('code entry remains scrollable with the keyboard open',
      (tester) async {
    await open(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 450);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.ensureVisible(find.text('Send another code').evaluate().isEmpty
        ? find.text('Resend code in 30s')
        : find.text('Send another code'));
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('an older server cooldown still allows code verification',
      (tester) async {
    final error = _failure(429, 'unused');
    error.response!.data = {
      'error': 'Please wait before requesting another code'
    };
    auth.requestError = error;
    await open(tester);
    await tester.tap(find.text('I have a code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications, hasLength(1));
    await finish(tester);
  });

  testWidgets('an address cooldown leaves verification available',
      (tester) async {
    auth.requestError = _failure(429, 'otp_cooldown', seconds: 20);
    await open(tester);
    await tester.tap(find.text('I have a code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications, hasLength(1));
    expect(auth.requests, hasLength(1));
    await finish(tester);
  });

  testWidgets('a delayed code completion cannot verify against a changed email',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.text('Use a different email'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'new@example.com');
    await tester.pump(const Duration(milliseconds: 350));
    expect(auth.verifications, isEmpty);
    await tester.tap(find.text('I have a code'));
    await tester.pump();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty);
    await finish(tester);
  });
}
