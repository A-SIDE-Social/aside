import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:aside/core/media/media_transform.dart';

void main() {
  group('MediaTransform construction and clamping', () {
    test('identity getter holds rotation=0, scale=1, offset=zero', () {
      expect(MediaTransform.identity.rotation, 0);
      expect(MediaTransform.identity.scale, 1);
      expect(MediaTransform.identity.offset, Offset.zero);
      expect(MediaTransform.identity.isIdentity, true);
    });

    test('rotation is clamped to ±π/12 (±15°)', () {
      // Exceeding positive side
      final over = MediaTransform(rotation: math.pi); // 180°
      expect(over.rotation, MediaTransform.maxRotation);
      // Exceeding negative side
      final under = MediaTransform(rotation: -math.pi);
      expect(under.rotation, -MediaTransform.maxRotation);
      // In-range passes through
      final ok = MediaTransform(rotation: 0.05);
      expect(ok.rotation, 0.05);
    });

    test('scale is clamped to [1.0, 3.0]', () {
      expect(MediaTransform(scale: 0.5).scale, 1.0);
      expect(MediaTransform(scale: 10.0).scale, 3.0);
      expect(MediaTransform(scale: 2.5).scale, 2.5);
    });

    test('isIdentity is only true for the exact no-op', () {
      expect(MediaTransform().isIdentity, true);
      expect(MediaTransform(rotation: 0.001).isIdentity, false);
      expect(MediaTransform(scale: 1.0001).isIdentity, false);
      expect(
        MediaTransform(offset: const Offset(1, 0)).isIdentity,
        false,
      );
    });

    test('copyWith overrides only provided fields', () {
      final base = MediaTransform(
        rotation: 0.1,
        scale: 1.5,
        offset: const Offset(5, 3),
      );
      final r = base.copyWith(rotation: 0.2);
      expect(r.rotation, 0.2);
      expect(r.scale, 1.5);
      expect(r.offset, const Offset(5, 3));

      final s = base.copyWith(scale: 2);
      expect(s.rotation, 0.1);
      expect(s.scale, 2);
      expect(s.offset, const Offset(5, 3));
    });
  });

  group('MediaTransform JSON roundtrip', () {
    test('identity serializes and restores', () {
      final json = MediaTransform.identity.toJson();
      final back = MediaTransform.fromJson(json);
      expect(back, MediaTransform.identity);
    });

    test('non-identity roundtrips exactly', () {
      final original = MediaTransform(
        rotation: 0.1,
        scale: 1.7,
        offset: const Offset(12, -4),
      );
      final back = MediaTransform.fromJson(original.toJson());
      expect(back.rotation, original.rotation);
      expect(back.scale, original.scale);
      expect(back.offset, original.offset);
      expect(back, original);
    });

    test('fromJson accepts missing fields (defaults to identity)', () {
      final back = MediaTransform.fromJson({});
      expect(back.isIdentity, true);
    });
  });

  group('minScaleForRotation', () {
    test('identity rotation needs scale 1.0 regardless of aspect', () {
      expect(MediaTransform.minScaleForRotation(0, 1.0), closeTo(1.0, 1e-9));
      expect(MediaTransform.minScaleForRotation(0, 1.5), closeTo(1.0, 1e-9));
      expect(MediaTransform.minScaleForRotation(0, 0.67), closeTo(1.0, 1e-9));
    });

    test('positive rotation increases required scale', () {
      final small = MediaTransform.minScaleForRotation(0.05, 1.0);
      final larger = MediaTransform.minScaleForRotation(0.15, 1.0);
      expect(small, greaterThan(1.0));
      expect(larger, greaterThan(small));
    });

    test('negative rotation matches positive (symmetric)', () {
      final pos = MediaTransform.minScaleForRotation(0.1, 1.0);
      final neg = MediaTransform.minScaleForRotation(-0.1, 1.0);
      expect(neg, closeTo(pos, 1e-9));
    });

    test('square aspect at 15° requires ≈ cos + sin', () {
      final theta = MediaTransform.maxRotation;
      final expected = math.cos(theta) + math.sin(theta);
      final computed = MediaTransform.minScaleForRotation(theta, 1.0);
      expect(computed, closeTo(expected, 1e-9));
    });
  });

  group('MediaTransform equality', () {
    test('equal when all fields match', () {
      final a = MediaTransform(rotation: 0.1, scale: 1.5);
      final b = MediaTransform(rotation: 0.1, scale: 1.5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('unequal when any field differs', () {
      expect(
        MediaTransform(rotation: 0.1),
        isNot(MediaTransform(rotation: 0.2)),
      );
      expect(
        MediaTransform(scale: 1.5),
        isNot(MediaTransform(scale: 2.0)),
      );
    });
  });
}
