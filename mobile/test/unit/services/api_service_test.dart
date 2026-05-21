import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/core/network/api_client.dart';
import 'package:aside/core/network/api_endpoints.dart';
import 'package:aside/core/network/api_service.dart';
import '../../helpers/mocks.dart';

// Mock ApiClient that exposes MockDio
class MockApiClient extends Mock implements ApiClient {
  final MockDio mockDio;
  MockApiClient(this.mockDio);

  @override
  Dio get dio => mockDio;
}

void main() {
  late MockDio mockDio;
  late ApiService apiService;

  setUp(() {
    mockDio = MockDio();
    final mockClient = MockApiClient(mockDio);
    apiService = ApiService(mockClient);
  });

  setUpAll(() {
    registerFallbackValue(RequestOptions(path: ''));
    registerFallbackValue(Options());
  });

  group('ApiService Auth', () {
    test('verifyOtp sends email and code in body', () async {
      when(() => mockDio.post(
            ApiEndpoints.verifyOtp,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'token': 'abc', 'user': {}},
            statusCode: 200,
          ));

      await apiService.verifyOtp('test@example.com', '123456');
      final captured = verify(() => mockDio.post(
            ApiEndpoints.verifyOtp,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['email'], 'test@example.com');
      expect(captured['code'], '123456');
    });

    test('verifyOtp includes optional invite_code and display_name', () async {
      when(() => mockDio.post(
            ApiEndpoints.verifyOtp,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'token': 'abc'},
            statusCode: 200,
          ));

      await apiService.verifyOtp('test@example.com', '123456',
          inviteCode: 'INV1', displayName: 'Alice');

      final captured = verify(() => mockDio.post(
            ApiEndpoints.verifyOtp,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['invite_code'], 'INV1');
      expect(captured['display_name'], 'Alice');
    });

    test('logout sends refresh_token via DELETE', () async {
      when(() => mockDio.delete(
            ApiEndpoints.logout,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'success': true},
            statusCode: 200,
          ));

      await apiService.logout('refresh-123');
      final captured = verify(() => mockDio.delete(
            ApiEndpoints.logout,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['refresh_token'], 'refresh-123');
    });
  });

  group('ApiService Feed', () {
    test('getFeed passes query params correctly', () async {
      when(() => mockDio.get(
            ApiEndpoints.feed,
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'posts': []},
            statusCode: 200,
          ));

      await apiService.getFeed(before: 'cursor-1', groupId: 'g1');
      final captured = verify(() => mockDio.get(
            ApiEndpoints.feed,
            queryParameters: captureAny(named: 'queryParameters'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['before'], 'cursor-1');
      expect(captured['group_id'], 'g1');
    });

    test('getFeed omits null params', () async {
      when(() => mockDio.get(
            ApiEndpoints.feed,
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'posts': []},
            statusCode: 200,
          ));

      await apiService.getFeed();
      final captured = verify(() => mockDio.get(
            ApiEndpoints.feed,
            queryParameters: captureAny(named: 'queryParameters'),
          )).captured.single as Map<String, dynamic>;

      expect(captured.containsKey('before'), isFalse);
      expect(captured.containsKey('group_id'), isFalse);
    });

    test('getFeed returns posts list from response', () async {
      when(() => mockDio.get(
            ApiEndpoints.feed,
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'posts': [
                {'id': 'p1'},
                {'id': 'p2'}
              ]
            },
            statusCode: 200,
          ));

      final result = await apiService.getFeed();
      // getFeed now returns the full response envelope so callers can
      // read has_older_posts alongside posts.
      expect(result, isMap);
      expect(result['posts'], isList);
      expect((result['posts'] as List).length, 2);
    });
  });

  group('ApiService Posts', () {
    test('createPost sends body with caption, media, and groupIds', () async {
      when(() => mockDio.post(
            ApiEndpoints.posts,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'post': {'id': 'p1'}
            },
            statusCode: 201,
          ));

      await apiService.createPost(
        caption: 'Hello',
        media: [
          {'key': 'abc', 'media_type': 'photo'}
        ],
        groupIds: ['g1'],
      );

      final captured = verify(() => mockDio.post(
            ApiEndpoints.posts,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['caption'], 'Hello');
      expect(captured['media'], hasLength(1));
      expect(captured['group_ids'], ['g1']);
    });

    test('deletePost calls DELETE on correct endpoint', () async {
      when(() => mockDio.delete(ApiEndpoints.post('p1'))).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: ''),
          data: {'success': true},
          statusCode: 200,
        ),
      );

      await apiService.deletePost('p1');
      verify(() => mockDio.delete(ApiEndpoints.post('p1'))).called(1);
    });
  });

  group('ApiService Conversations', () {
    test('createConversation sends user_id', () async {
      when(() => mockDio.post(
            ApiEndpoints.conversations,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'conversation': {'id': 'c1'}
            },
            statusCode: 201,
          ));

      await apiService.createConversation('u2');
      final captured = verify(() => mockDio.post(
            ApiEndpoints.conversations,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['user_id'], 'u2');
    });

    test('sendMessage sends body and mediaUrl', () async {
      when(() => mockDio.post(
            ApiEndpoints.messages('c1'),
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'message': {'id': 'm1'}
            },
            statusCode: 201,
          ));

      await apiService.sendMessage('c1',
          body: 'Hi', mediaUrl: 'https://example.com/img.jpg');

      final captured = verify(() => mockDio.post(
            ApiEndpoints.messages('c1'),
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['body'], 'Hi');
      expect(captured['media_url'], 'https://example.com/img.jpg');
    });

    test('sendMessage can send E2EE epoch metadata', () async {
      when(() => mockDio.post(
            ApiEndpoints.messages('c1'),
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'message': {'id': 'm1'}
            },
            statusCode: 201,
          ));

      await apiService.sendMessage(
        'c1',
        ciphertextBase64: 'abc',
        envelopeType: 'signal_group',
        protocolVersion: 1,
        conversationEpoch: 4,
      );

      final captured = verify(() => mockDio.post(
            ApiEndpoints.messages('c1'),
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['ciphertext'], 'abc');
      expect(captured['envelope_type'], 'signal_group');
      expect(captured['protocol_version'], 1);
      expect(captured['conversation_epoch'], 4);
    });
  });

  group('ApiService Devices', () {
    test('registerDeviceToken sends token and platform', () async {
      when(() => mockDio.post(
            ApiEndpoints.deviceToken,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {},
            statusCode: 200,
          ));

      await apiService.registerDeviceToken('fcm-token', 'ios');
      final captured = verify(() => mockDio.post(
            ApiEndpoints.deviceToken,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['token'], 'fcm-token');
      expect(captured['platform'], 'ios');
    });

    test('unregisterDeviceToken sends token via DELETE', () async {
      when(() => mockDio.delete(
            ApiEndpoints.deviceToken,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {},
            statusCode: 200,
          ));

      await apiService.unregisterDeviceToken('fcm-token');
      final captured = verify(() => mockDio.delete(
            ApiEndpoints.deviceToken,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['token'], 'fcm-token');
    });
  });

  group('ApiService Contacts', () {
    test('syncContacts sends hashes array', () async {
      when(() => mockDio.post(
            ApiEndpoints.contactsSync,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'matches': [
                {'id': 'u1', 'display_name': 'Alice', 'is_mutual': false}
              ]
            },
            statusCode: 200,
          ));

      final result = await apiService.syncContacts(['hash1', 'hash2', 'hash3']);
      final captured = verify(() => mockDio.post(
            ApiEndpoints.contactsSync,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['hashes'], ['hash1', 'hash2', 'hash3']);
      expect(result, isList);
      expect((result as List).length, 1);
    });

    test('getContactMatches returns cached matches', () async {
      when(() => mockDio.get(ApiEndpoints.contactsMatches))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'matches': [
                    {'id': 'u1', 'display_name': 'Bob', 'is_mutual': true}
                  ]
                },
                statusCode: 200,
              ));

      final result = await apiService.getContactMatches();
      expect(result, isList);
      expect((result as List).first['is_mutual'], true);
    });
  });
}
