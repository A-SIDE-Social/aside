import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Channel matching iOS ContactsHandler + Android ContactsHandler.
const _channel = MethodChannel('com.lab1908.instadamn/contacts');

/// Service that handles contact syncing for friend discovery.
/// Hashes both phone numbers and email addresses from the user's contacts.
class ContactSyncService {
  /// Request contacts permission and return hashed phone numbers + emails.
  /// Returns null if permission denied.
  static Future<List<String>?> getHashedContacts() async {
    final granted = await _channel.invokeMethod<bool>('requestPermission');
    if (granted != true) return null;

    final hashes = <String>{};

    // Hash phone numbers
    final List<dynamic>? phoneNumbers =
        await _channel.invokeMethod<List<dynamic>>('getPhoneNumbers');
    if (phoneNumbers != null) {
      for (final raw in phoneNumbers) {
        final normalized = _normalizePhone(raw as String);
        if (normalized != null) {
          hashes.add(_hash(normalized));
        }
      }
    }

    // Hash email addresses
    final List<dynamic>? emails =
        await _channel.invokeMethod<List<dynamic>>('getEmailAddresses');
    if (emails != null) {
      for (final raw in emails) {
        final email = (raw as String).trim().toLowerCase();
        if (email.isNotEmpty) {
          hashes.add(_hash(email));
        }
      }
    }

    return hashes.toList();
  }

  /// Normalize a phone number to E.164 format.
  /// Currently handles US numbers only (+1 prefix).
  static String? _normalizePhone(String raw) {
    // Strip everything except digits and leading +
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');

    if (digits.length == 10) {
      // US number without country code
      return '+1$digits';
    } else if (digits.length == 11 && digits.startsWith('1')) {
      // US number with leading 1
      return '+$digits';
    } else if (digits.length > 10) {
      // International number — assume already has country code
      return '+$digits';
    }

    // Too short or invalid
    return null;
  }

  /// SHA-256 hash of a string (phone number or email).
  static String _hash(String value) {
    return sha256.convert(utf8.encode(value)).toString();
  }
}
