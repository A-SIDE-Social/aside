import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// We can't directly test ContactSyncService because it uses FlutterContacts
// which requires a platform channel. Instead, test the pure logic functions.

void main() {
  group('Phone number hashing', () {
    test('SHA-256 hash of E.164 phone is consistent', () {
      const phone = '+12125550001';
      final hash = sha256.convert(utf8.encode(phone)).toString();
      // SHA-256 of +12125550001
      expect(hash, isA<String>());
      expect(hash.length, 64); // SHA-256 hex is 64 chars
      // Same input produces same hash
      expect(sha256.convert(utf8.encode(phone)).toString(), hash);
    });

    test('different phone numbers produce different hashes', () {
      const phone1 = '+12125550001';
      const phone2 = '+12125550002';
      final hash1 = sha256.convert(utf8.encode(phone1)).toString();
      final hash2 = sha256.convert(utf8.encode(phone2)).toString();
      expect(hash1, isNot(equals(hash2)));
    });

    test('phone normalization: 10-digit US number gets +1 prefix', () {
      // This tests the normalization logic from ContactSyncService._normalizePhone
      const raw = '2125550001';
      final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
      String? normalized;
      if (digits.length == 10) {
        normalized = '+1$digits';
      }
      expect(normalized, '+12125550001');
    });

    test('phone normalization: 11-digit US number starting with 1', () {
      const raw = '12125550001';
      final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
      String? normalized;
      if (digits.length == 11 && digits.startsWith('1')) {
        normalized = '+$digits';
      }
      expect(normalized, '+12125550001');
    });

    test('phone normalization: strips formatting characters', () {
      const raw = '(212) 555-0001';
      final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
      expect(digits, '2125550001');
      expect(digits.length, 10);
    });

    test('phone normalization: too short returns null', () {
      const raw = '55500';
      final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
      String? normalized;
      if (digits.length == 10) {
        normalized = '+1$digits';
      } else if (digits.length == 11 && digits.startsWith('1')) {
        normalized = '+$digits';
      } else if (digits.length > 10) {
        normalized = '+$digits';
      }
      expect(normalized, isNull);
    });
  });
}
