import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:aside/core/media/film_filters.dart';

void main() {
  group('FilmFilter', () {
    test('identity filter produces identity matrix', () {
      const filter = FilmFilter(id: 'test', name: 'Test');
      final matrix = filter.toColorMatrix();
      expect(matrix.length, 20);
      // Identity: diagonal is 1, rest is 0
      expect(matrix[0], 1); // R_r
      expect(matrix[6], 1); // G_g
      expect(matrix[12], 1); // B_b
      expect(matrix[18], 1); // A_a
      // Offsets are 0
      expect(matrix[4], 0); // R offset
      expect(matrix[9], 0); // G offset
      expect(matrix[14], 0); // B offset
    });

    test('isNone is true only for id "none"', () {
      expect(FilmFilters.none.isNone, true);
      expect(FilmFilters.hardMono.isNone, false);
      expect(FilmFilters.warmFade.isNone, false);
    });

    test('toColorFilter returns a ColorFilter', () {
      final cf = FilmFilters.warmFade.toColorFilter();
      expect(cf, isA<ColorFilter>());
    });

    test('brightness shifts offsets positively', () {
      const filter = FilmFilter(id: 'b', name: 'Bright', brightness: 0.5);
      final matrix = filter.toColorMatrix();
      // R, G, B offsets should be positive (0.5 * 255 = 127.5)
      expect(matrix[4], closeTo(127.5, 0.01));
      expect(matrix[9], closeTo(127.5, 0.01));
      expect(matrix[14], closeTo(127.5, 0.01));
    });

    test('negative brightness shifts offsets negatively', () {
      const filter = FilmFilter(id: 'b', name: 'Dark', brightness: -0.5);
      final matrix = filter.toColorMatrix();
      expect(matrix[4], closeTo(-127.5, 0.01));
    });

    test('saturation 0 produces B&W (desaturated) matrix', () {
      const filter = FilmFilter(id: 'bw', name: 'BW', saturation: 0);
      final matrix = filter.toColorMatrix();
      // R row: all channels should be luma weights (0.2126, 0.7152, 0.0722)
      expect(matrix[0], closeTo(0.2126, 0.001));
      expect(matrix[1], closeTo(0.7152, 0.001));
      expect(matrix[2], closeTo(0.0722, 0.001));
      // G and B rows follow same pattern
      expect(matrix[5], closeTo(0.2126, 0.001));
      expect(matrix[10], closeTo(0.2126, 0.001));
    });

    test('contrast > 1 increases scale', () {
      const filter = FilmFilter(id: 'c', name: 'Hi', contrast: 1.5);
      final matrix = filter.toColorMatrix();
      // Diagonal should be 1.5 (scale)
      expect(matrix[0], closeTo(1.5, 0.01));
      expect(matrix[6], closeTo(1.5, 0.01));
      // Offset should be negative (pulling midpoint down)
      expect(matrix[4], lessThan(0));
    });

    test('temperature positive warms (boosts red, cuts blue)', () {
      const filter = FilmFilter(id: 't', name: 'Warm', temperature: 1.0);
      final matrix = filter.toColorMatrix();
      // R offset positive, B offset negative
      expect(matrix[4], greaterThan(0));
      expect(matrix[14], lessThan(0));
    });

    test('fade lifts black point', () {
      const filter = FilmFilter(id: 'f', name: 'Fade', fade: 0.1);
      final matrix = filter.toColorMatrix();
      // Offsets should be positive (lifting blacks)
      expect(matrix[4], greaterThan(0));
      expect(matrix[9], greaterThan(0));
      expect(matrix[14], greaterThan(0));
      // Diagonal should be < 1 (compressing range)
      expect(matrix[0], lessThan(1));
    });

    test('composite matrix combines all transforms', () {
      const filter = FilmFilter(
        id: 'combo',
        name: 'Combo',
        brightness: 0.1,
        contrast: 1.2,
        saturation: 0.8,
        temperature: 0.1,
        tint: -0.05,
        fade: 0.05,
      );
      final matrix = filter.toColorMatrix();
      expect(matrix.length, 20);
      // Should not be identity
      expect(matrix[0], isNot(1.0));
      // Alpha channel should be unchanged
      expect(matrix[18], 1.0);
      expect(matrix[15], 0.0);
      expect(matrix[16], 0.0);
      expect(matrix[17], 0.0);
    });
  });

  group('FilmFilters presets', () {
    test('all returns 8 filters', () {
      expect(FilmFilters.all.length, 8);
    });

    test('B&W filters are last in the list', () {
      final last = FilmFilters.all.sublist(FilmFilters.all.length - 2);
      expect(last.map((f) => f.id), ['hard_mono', 'soft_mono']);
    });

    test('first filter is Original (none)', () {
      expect(FilmFilters.all.first.id, 'none');
      expect(FilmFilters.all.first.name, 'Original');
    });

    test('byId returns correct filter', () {
      expect(FilmFilters.byId('hard_mono').name, 'Hard Mono');
      expect(FilmFilters.byId('warm_fade').name, 'Warm Fade');
    });

    test('byId returns none for unknown id', () {
      expect(FilmFilters.byId('unknown').id, 'none');
    });

    test('Hard Mono is black and white (saturation 0)', () {
      expect(FilmFilters.hardMono.saturation, 0);
    });

    test('Soft Mono is black and white with more fade', () {
      expect(FilmFilters.softMono.saturation, 0);
      expect(FilmFilters.softMono.fade, greaterThan(FilmFilters.hardMono.fade));
    });

    test('Warm Fade is warm and slightly desaturated', () {
      expect(FilmFilters.warmFade.temperature, greaterThan(0));
      expect(FilmFilters.warmFade.saturation, lessThan(1));
    });

    test('Cool Vivid is cool and saturated', () {
      expect(FilmFilters.coolVivid.temperature, lessThan(0));
      expect(FilmFilters.coolVivid.saturation, greaterThan(1));
    });

    test('Summer Punch is warm and vivid', () {
      expect(FilmFilters.summerPunch.temperature, greaterThan(0));
      expect(FilmFilters.summerPunch.saturation, greaterThan(1));
    });

    test('Instant Warm is warm with lifted blacks', () {
      expect(FilmFilters.instantWarm.temperature, greaterThan(0));
      expect(FilmFilters.instantWarm.fade, greaterThan(0));
      expect(FilmFilters.instantWarm.contrast, lessThan(1));
    });

    test('Instant Cool is cool with lifted blacks', () {
      expect(FilmFilters.instantCool.temperature, lessThan(0));
      expect(FilmFilters.instantCool.fade,
          greaterThan(FilmFilters.instantWarm.fade));
      expect(FilmFilters.instantCool.saturation, lessThan(1));
    });

    test('all filter matrices have 20 elements', () {
      for (final filter in FilmFilters.all) {
        expect(filter.toColorMatrix().length, 20,
            reason: '${filter.name} matrix should have 20 elements');
      }
    });

    test('all filters preserve alpha channel', () {
      for (final filter in FilmFilters.all) {
        final m = filter.toColorMatrix();
        expect(m[15], 0, reason: '${filter.name}: A_r should be 0');
        expect(m[16], 0, reason: '${filter.name}: A_g should be 0');
        expect(m[17], 0, reason: '${filter.name}: A_b should be 0');
        expect(m[18], 1, reason: '${filter.name}: A_a should be 1');
        expect(m[19], 0, reason: '${filter.name}: A_offset should be 0');
      }
    });
  });
}
