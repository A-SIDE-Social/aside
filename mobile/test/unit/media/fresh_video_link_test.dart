import 'package:aside/core/media/fresh_video_link.dart';
import 'package:aside/core/network/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockApiService extends Mock implements ApiService {}

void main() {
  group('openWithFreshLink', () {
    const expired = 'https://media.example.com/a.mp4?sig=old';
    const renewed = 'https://media.example.com/a.mp4?sig=new';

    test('uses the first link when it works, without asking for another',
        () async {
      var asked = false;
      final result = await openWithFreshLink<String>(
        expired,
        open: (url) async => url,
        freshUrl: () async {
          asked = true;
          return renewed;
        },
      );
      expect(result, expired);
      expect(asked, isFalse);
    });

    test('retries once with a new link when the first fails', () async {
      final attempts = <String>[];
      final result = await openWithFreshLink<String>(
        expired,
        open: (url) async {
          attempts.add(url);
          if (url == expired) throw Exception('expired');
          return url;
        },
        freshUrl: () async => renewed,
      );
      expect(result, renewed);
      expect(attempts, [expired, renewed]);
    });

    test('a link without a query fails without making an API call', () async {
      var asked = false;
      await expectLater(
        openWithFreshLink<String>(
          'https://media.example.com/a.mp4',
          open: (_) async => throw Exception('network'),
          freshUrl: () async {
            asked = true;
            return renewed;
          },
        ),
        throwsException,
      );
      expect(asked, isFalse);
    });

    for (final fresh in [null, expired]) {
      test('gives up when the new link is $fresh', () async {
        var opens = 0;
        await expectLater(
          openWithFreshLink<String>(
            expired,
            open: (_) async {
              opens++;
              throw Exception('expired');
            },
            freshUrl: () async => fresh,
          ),
          throwsException,
        );
        expect(opens, 1);
      });
    }

    test('reports the video failure when asking for a new link fails',
        () async {
      await expectLater(
        openWithFreshLink<String>(
          expired,
          open: (_) async => throw StateError('video failed'),
          freshUrl: () async => throw Exception('offline'),
        ),
        throwsStateError,
      );
    });

    test('does not retry a second time', () async {
      var opens = 0;
      await expectLater(
        openWithFreshLink<String>(
          expired,
          open: (_) async {
            opens++;
            throw Exception('still failing');
          },
          freshUrl: () async => renewed,
        ),
        throwsException,
      );
      expect(opens, 2);
    });
  });

  group('freshPostMediaUrl', () {
    late _MockApiService api;
    setUp(() => api = _MockApiService());

    test('returns the current link for the same file', () async {
      when(() => api.getPost('p1')).thenAnswer((_) async => {
            'media': [
              {'media_url': 'https://media.example.com/other.mp4?sig=new'},
              {'media_url': 'https://media.example.com/a.mp4?sig=new'},
            ],
          });
      expect(
        await freshPostMediaUrl(
            api, 'p1', 'https://media.example.com/a.mp4?sig=old'),
        'https://media.example.com/a.mp4?sig=new',
      );
    });

    test('returns null when the post no longer has that file', () async {
      when(() => api.getPost('p1')).thenAnswer((_) async => {
            'media': [
              {'media_url': 'https://media.example.com/other.mp4?sig=new'},
            ],
          });
      expect(
        await freshPostMediaUrl(
            api, 'p1', 'https://media.example.com/a.mp4?sig=old'),
        isNull,
      );
    });

    test('returns null for a response without media', () async {
      when(() => api.getPost('p1')).thenAnswer((_) async => {'id': 'p1'});
      expect(
        await freshPostMediaUrl(
            api, 'p1', 'https://media.example.com/a.mp4?sig=old'),
        isNull,
      );
    });
  });
}
