import 'package:aside/core/cache/image_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a URL without a query keeps its existing cache key', () {
    const url = 'https://media.example.com/photo.jpeg';
    expect(mediaCacheKey(url), url);
  });

  test('different query strings on one file share a cache key', () {
    const first = 'https://media.example.com/photo.jpeg?X-Expires=600&sig=a';
    const second = 'https://media.example.com/photo.jpeg?X-Expires=900&sig=b';
    expect(mediaCacheKey(first), 'https://media.example.com/photo.jpeg');
    expect(mediaCacheKey(first), mediaCacheKey(second));
  });

  test('different files keep different cache keys', () {
    expect(
      mediaCacheKey('https://media.example.com/a.jpeg?sig=same'),
      isNot(mediaCacheKey('https://media.example.com/b.jpeg?sig=same')),
    );
  });
}
