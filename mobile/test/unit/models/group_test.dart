import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/group.dart';
import '../../helpers/fixtures.dart';

void main() {
  group('Group', () {
    test('fromJson parses all fields', () {
      final json = groupJson(
        id: 'g1',
        userId: 'u1',
        name: 'Close Friends',
        color: '#FF0000',
        position: 3,
        createdAt: '2025-01-15T10:00:00.000Z',
      );
      final grp = Group.fromJson(json);

      expect(grp.id, 'g1');
      expect(grp.userId, 'u1');
      expect(grp.name, 'Close Friends');
      expect(grp.color, '#FF0000');
      expect(grp.position, 3);
      expect(grp.createdAt, DateTime.utc(2025, 1, 15, 10));
    });

    test('fromJson handles null color', () {
      final grp = Group.fromJson(groupJson());
      expect(grp.color, isNull);
    });

    test('fromJson defaults position to 0 when null', () {
      final json = groupJson();
      json.remove('position');
      final grp = Group.fromJson(json);
      expect(grp.position, 0);
    });

    test('toJson roundtrip preserves all fields', () {
      final grp =
          Group.fromJson(groupJson(id: 'g2', name: 'Family', color: '#00FF00'));
      final roundtripped = Group.fromJson(grp.toJson());

      expect(roundtripped.id, grp.id);
      expect(roundtripped.name, 'Family');
      expect(roundtripped.color, '#00FF00');
    });
  });
}
