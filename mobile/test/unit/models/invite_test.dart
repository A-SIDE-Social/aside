import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/invite.dart';
import '../../helpers/fixtures.dart';

void main() {
  group('Invite', () {
    test('fromJson parses all fields', () {
      final json = inviteJson(
        id: 'inv-1',
        code: 'XYZ789',
        status: 'used',
        expiresAt: '2025-02-01T00:00:00.000Z',
        createdAt: '2025-01-01T00:00:00.000Z',
        usedByUserId: 'u2',
        usedAt: '2025-01-15T10:00:00.000Z',
      );
      final invite = Invite.fromJson(json);

      expect(invite.id, 'inv-1');
      expect(invite.code, 'XYZ789');
      expect(invite.status, 'used');
      expect(invite.expiresAt, DateTime.utc(2025, 2, 1));
      expect(invite.createdAt, DateTime.utc(2025, 1, 1));
      expect(invite.usedByUserId, 'u2');
      expect(invite.usedAt, DateTime.utc(2025, 1, 15, 10));
    });

    test('fromJson handles null usedByUserId and usedAt', () {
      final invite = Invite.fromJson(inviteJson());
      expect(invite.usedByUserId, isNull);
      expect(invite.usedAt, isNull);
    });

    test('toJson roundtrip preserves all fields', () {
      final invite = Invite.fromJson(inviteJson(
        id: 'inv-2',
        code: 'ABC123',
        usedByUserId: 'u3',
        usedAt: '2025-01-20T00:00:00.000Z',
      ));
      final roundtripped = Invite.fromJson(invite.toJson());

      expect(roundtripped.id, invite.id);
      expect(roundtripped.code, invite.code);
      expect(roundtripped.usedByUserId, invite.usedByUserId);
      expect(roundtripped.usedAt, invite.usedAt);
    });

    group('copyWith', () {
      test('copies with new status', () {
        final invite = Invite.fromJson(inviteJson(status: 'pending'));
        final updated = invite.copyWith(status: 'sent');

        expect(updated.status, 'sent');
        expect(updated.id, invite.id);
        expect(updated.code, invite.code);
        expect(updated.expiresAt, invite.expiresAt);
        expect(updated.createdAt, invite.createdAt);
        expect(updated.usedByUserId, invite.usedByUserId);
      });

      test('copies without changes when no args provided', () {
        final invite = Invite.fromJson(inviteJson(status: 'pending'));
        final copied = invite.copyWith();

        expect(copied.status, 'pending');
        expect(copied.id, invite.id);
        expect(copied.code, invite.code);
      });

      test('sent status roundtrip', () {
        final invite = Invite.fromJson(inviteJson(status: 'pending'));
        final sent = invite.copyWith(status: 'sent');
        final json = sent.toJson();
        final parsed = Invite.fromJson(json);

        expect(parsed.status, 'sent');
      });
    });

    group('status values', () {
      test('parses pending status', () {
        final invite = Invite.fromJson(inviteJson(status: 'pending'));
        expect(invite.status, 'pending');
      });

      test('parses sent status', () {
        final invite = Invite.fromJson(inviteJson(status: 'sent'));
        expect(invite.status, 'sent');
      });

      test('parses used status', () {
        final invite = Invite.fromJson(inviteJson(status: 'used'));
        expect(invite.status, 'used');
      });

      test('parses revoked status', () {
        final invite = Invite.fromJson(inviteJson(status: 'revoked'));
        expect(invite.status, 'revoked');
      });
    });
  });
}
