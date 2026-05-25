import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/core/network/api_service.dart';
import 'package:aside/core/platform/push_notification_service.dart';
import 'package:aside/core/storage/secure_storage.dart';

class MockApiService extends Mock implements ApiService {}

class MockPushNotificationService extends Mock
    implements PushNotificationService {}

class MockSecureStorage extends Mock implements SecureStorage {}

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

class MockDio extends Mock implements Dio {}
