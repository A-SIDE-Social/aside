// Unit tests for the personal-invite-link surface on ApiService:
//   - GET /v1/invite-link
//   - POST /v1/invite-link/regenerate
//   - POST /v1/invite-link/request
//   - GET /v1/users/by-slug/:slug
//   - DELETE /v1/follows/inbound/:user_id
//
// Pure mock-Dio style, mirrors api_service_test.dart. No network, no
// router, no widget tree — just verifies the ApiService wraps endpoints
// with the right verbs, paths, payloads, and response shapes.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/core/network/api_client.dart';
import 'package:aside/core/network/api_endpoints.dart';
import 'package:aside/core/network/api_service.dart';
import '../../helpers/mocks.dart';

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

  group('ApiEndpoints', () {
    test('invite-link routes use the expected paths', () {
      expect(ApiEndpoints.inviteLink, '/v1/invite-link');
      expect(ApiEndpoints.regenerateInviteLink, '/v1/invite-link/regenerate');
      expect(ApiEndpoints.requestInviteLink, '/v1/invite-link/request');
    });

    test('userBySlug interpolates the slug into the path', () {
      expect(
        ApiEndpoints.userBySlug('k7m2pq9xj4n6'),
        '/v1/users/by-slug/k7m2pq9xj4n6',
      );
    });

    test('declineInbound interpolates the user_id into the path', () {
      expect(
        ApiEndpoints.declineInbound('user-123'),
        '/v1/follows/inbound/user-123',
      );
    });
  });

  group('ApiService.getInviteLink', () {
    test('GETs /v1/invite-link and returns slug + url', () async {
      when(() => mockDio.get(ApiEndpoints.inviteLink)).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: ''),
          data: {
            'slug': 'k7m2pq9xj4n6',
            'url': 'https://example.com/k7m2pq9xj4n6',
          },
          statusCode: 200,
        ),
      );

      final result = await apiService.getInviteLink();
      verify(() => mockDio.get(ApiEndpoints.inviteLink)).called(1);
      expect(result['slug'], 'k7m2pq9xj4n6');
      expect(result['url'], 'https://example.com/k7m2pq9xj4n6');
    });
  });

  group('ApiService.regenerateInviteLink', () {
    test('POSTs /v1/invite-link/regenerate and returns the new payload',
        () async {
      when(() => mockDio.post(ApiEndpoints.regenerateInviteLink))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'slug': 'newslugaaaaa',
                  'url': 'https://example.com/newslugaaaaa',
                },
                statusCode: 200,
              ));

      final result = await apiService.regenerateInviteLink();
      verify(() => mockDio.post(ApiEndpoints.regenerateInviteLink)).called(1);
      expect(result['slug'], 'newslugaaaaa');
    });
  });

  group('ApiService.requestFromSlug', () {
    test('POSTs /v1/invite-link/request with the slug in the body', () async {
      when(() => mockDio.post(
            ApiEndpoints.requestInviteLink,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'status': 'requested'},
            statusCode: 201,
          ));

      final result = await apiService.requestFromSlug('k7m2pq9xj4n6');
      final captured = verify(() => mockDio.post(
            ApiEndpoints.requestInviteLink,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['slug'], 'k7m2pq9xj4n6');
      expect(result['status'], 'requested');
    });

    test('passes URLs through to the slug field verbatim', () async {
      // The server's `extractSlug` extracts the slug from the URL —
      // the client doesn't need to parse, just forward.
      when(() => mockDio.post(
            ApiEndpoints.requestInviteLink,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'status': 'requested'},
            statusCode: 201,
          ));

      await apiService.requestFromSlug('https://example.com/k7m2pq9xj4n6');
      final captured = verify(() => mockDio.post(
            ApiEndpoints.requestInviteLink,
            data: captureAny(named: 'data'),
          )).captured.single as Map<String, dynamic>;

      expect(captured['slug'], 'https://example.com/k7m2pq9xj4n6');
    });

    test('surfaces server status values verbatim', () async {
      // The screen branches on these — exercise each so a contract
      // change between server and client surfaces in tests, not in
      // production.
      for (final status in [
        'requested',
        'already_following',
        'already_mutual',
        'self',
      ]) {
        when(() => mockDio.post(
              ApiEndpoints.requestInviteLink,
              data: any(named: 'data'),
            )).thenAnswer((_) async => Response(
              requestOptions: RequestOptions(path: ''),
              data: {'status': status},
              statusCode: 200,
            ));
        final result = await apiService.requestFromSlug('k7m2pq9xj4n6');
        expect(result['status'], status);
      }
    });
  });

  group('ApiService.getUserBySlug', () {
    test('GETs /v1/users/by-slug/:slug and unwraps the user envelope',
        () async {
      when(() => mockDio.get(ApiEndpoints.userBySlug('k7m2pq9xj4n6')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'user': {
                    'id': 'u1',
                    'display_name': 'Alice',
                    'avatar_url': null,
                  },
                },
                statusCode: 200,
              ));

      final user = await apiService.getUserBySlug('k7m2pq9xj4n6');
      verify(() => mockDio.get(ApiEndpoints.userBySlug('k7m2pq9xj4n6')))
          .called(1);
      expect(user['id'], 'u1');
      expect(user['display_name'], 'Alice');
    });

    test('propagates 404 as a DioException for stale slug rendering', () async {
      // The SendRequestScreen branches on this exact shape to render
      // the "invite link no longer valid" empty state.
      when(() => mockDio.get(ApiEndpoints.userBySlug('aaaaaaaaaaaa')))
          .thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        response: Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 404,
          data: {'error': 'Invite link not found'},
        ),
      ));

      await expectLater(
        apiService.getUserBySlug('aaaaaaaaaaaa'),
        throwsA(isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          404,
        )),
      );
    });
  });

  group('ApiService.declineInbound', () {
    test('DELETEs /v1/follows/inbound/:user_id', () async {
      when(() => mockDio.delete(ApiEndpoints.declineInbound('u-2')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: null,
                statusCode: 204,
              ));

      await apiService.declineInbound('u-2');
      verify(() => mockDio.delete(ApiEndpoints.declineInbound('u-2')))
          .called(1);
    });
  });
}
