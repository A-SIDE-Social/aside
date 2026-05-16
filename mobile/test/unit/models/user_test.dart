import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/user.dart';
import '../../helpers/fixtures.dart';

void main() {
  group('User', () {
    test('fromJson parses all fields correctly', () {
      final json = userJson(
        id: 'u1',
        displayName: 'Alice',
        avatarUrl: 'https://example.com/avatar.jpg',
        bio: 'Hello world',
        email: 'alice@example.com',
        subscriptionStatus: 'active',
        trialEndsAt: '2025-06-01T00:00:00.000Z',
        createdAt: '2025-01-15T10:30:00.000Z',
      );
      final user = User.fromJson(json);

      expect(user.id, 'u1');
      expect(user.displayName, 'Alice');
      expect(user.avatarUrl, 'https://example.com/avatar.jpg');
      expect(user.bio, 'Hello world');
      expect(user.email, 'alice@example.com');
      expect(user.subscriptionStatus, 'active');
      expect(user.trialEndsAt, DateTime.utc(2025, 6, 1));
      expect(user.createdAt, DateTime.utc(2025, 1, 15, 10, 30));
    });

    test('fromJson handles null optional fields', () {
      final json = userJson();
      json.remove('avatar_url');
      json.remove('bio');
      json.remove('email');
      json.remove('phone_e164');
      json.remove('trial_ends_at');

      final user = User.fromJson(json);

      expect(user.avatarUrl, isNull);
      expect(user.bio, isNull);
      expect(user.email, isNull);
      expect(user.phoneE164, isNull);
      expect(user.trialEndsAt, isNull);
    });

    test('fromJson defaults subscriptionStatus to free when missing', () {
      final json = userJson();
      json.remove('subscription_status');
      final user = User.fromJson(json);
      expect(user.subscriptionStatus, 'free');
    });

    test('fromJson defaults createdAt to now when missing', () {
      final json = userJson();
      json.remove('created_at');
      final before = DateTime.now();
      final user = User.fromJson(json);
      expect(
          user.createdAt.isAfter(before.subtract(const Duration(seconds: 1))),
          isTrue);
    });

    test('toJson produces correct snake_case keys', () {
      final user = User.fromJson(userJson(id: 'u1', displayName: 'Bob'));
      final json = user.toJson();

      expect(json['id'], 'u1');
      expect(json['display_name'], 'Bob');
      expect(json.containsKey('displayName'), isFalse);
    });

    test('toJson roundtrip preserves all fields', () {
      final original = userJson(
        id: 'u2',
        displayName: 'Charlie',
        avatarUrl: 'https://example.com/pic.jpg',
        bio: 'My bio',
        subscriptionStatus: 'active',
      );
      final user = User.fromJson(original);
      final roundtripped = User.fromJson(user.toJson());

      expect(roundtripped.id, user.id);
      expect(roundtripped.displayName, user.displayName);
      expect(roundtripped.avatarUrl, user.avatarUrl);
      expect(roundtripped.bio, user.bio);
      expect(roundtripped.subscriptionStatus, user.subscriptionStatus);
    });

    test('copyWith replaces specified fields only', () {
      final user = testUser(id: 'u1', displayName: 'Alice');
      final updated = user.copyWith(displayName: 'Bob');

      expect(updated.id, 'u1');
      expect(updated.displayName, 'Bob');
    });

    test('copyWith with no arguments returns equivalent object', () {
      final user = testUser();
      final copy = user.copyWith();

      expect(copy.id, user.id);
      expect(copy.displayName, user.displayName);
      expect(copy.subscriptionStatus, user.subscriptionStatus);
    });
  });
}
