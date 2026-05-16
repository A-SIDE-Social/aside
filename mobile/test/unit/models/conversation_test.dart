import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/conversation.dart';
import '../../helpers/fixtures.dart';

void main() {
  group('Conversation', () {
    test('fromJson parses all fields', () {
      final json = conversationJson(
        id: 'conv-1',
        otherUserId: 'u2',
        otherDisplayName: 'Alice',
        otherAvatarUrl: 'https://example.com/alice.jpg',
        unreadCount: 3,
        lastMessageAt: '2025-01-15T12:00:00.000Z',
        lastReadAt: '2025-01-15T11:00:00.000Z',
      );
      final conv = Conversation.fromJson(json);

      expect(conv.id, 'conv-1');
      expect(conv.otherUserId, 'u2');
      expect(conv.otherDisplayName, 'Alice');
      expect(conv.otherAvatarUrl, 'https://example.com/alice.jpg');
      expect(conv.unreadCount, 3);
      expect(conv.lastMessageAt, DateTime.utc(2025, 1, 15, 12));
      expect(conv.lastReadAt, DateTime.utc(2025, 1, 15, 11));
    });

    test('fromJson handles null lastMessageAt, otherAvatarUrl, lastReadAt', () {
      final conv = Conversation.fromJson(conversationJson());
      expect(conv.lastMessageAt, isNull);
      expect(conv.otherAvatarUrl, isNull);
      expect(conv.lastReadAt, isNull);
    });

    test('fromJson parses unreadCount from string', () {
      final json = conversationJson(unreadCount: '5');
      final conv = Conversation.fromJson(json);
      expect(conv.unreadCount, 5);
    });

    test('fromJson parses unreadCount from int', () {
      final json = conversationJson(unreadCount: 7);
      final conv = Conversation.fromJson(json);
      expect(conv.unreadCount, 7);
    });

    test('fromJson defaults unreadCount to 0 when null', () {
      final json = conversationJson();
      json.remove('unread_count');
      final conv = Conversation.fromJson(json);
      expect(conv.unreadCount, 0);
    });

    test('toJson roundtrip preserves all fields', () {
      final original = conversationJson(
        id: 'conv-2',
        otherDisplayName: 'Bob',
        unreadCount: 2,
      );
      final conv = Conversation.fromJson(original);
      final roundtripped = Conversation.fromJson(conv.toJson());

      expect(roundtripped.id, conv.id);
      expect(roundtripped.otherDisplayName, conv.otherDisplayName);
      expect(roundtripped.unreadCount, conv.unreadCount);
    });
  });

  group('Message', () {
    test('fromJson parses all fields', () {
      final json = messageJson(
        id: 'msg-1',
        conversationId: 'conv-1',
        senderId: 'u1',
        body: 'Hello!',
        createdAt: '2025-01-15T12:00:00.000Z',
        senderDisplayName: 'Alice',
      );
      final msg = Message.fromJson(json);

      expect(msg.id, 'msg-1');
      expect(msg.conversationId, 'conv-1');
      expect(msg.senderId, 'u1');
      expect(msg.body, 'Hello!');
      expect(msg.createdAt, DateTime.utc(2025, 1, 15, 12));
      expect(msg.senderDisplayName, 'Alice');
    });

    test('fromJson handles null body, mediaUrl, senderAvatarUrl', () {
      final json = messageJson();
      json['body'] = null;
      json['media_url'] = null;
      json['sender_avatar_url'] = null;
      final msg = Message.fromJson(json);

      expect(msg.body, isNull);
      expect(msg.mediaUrl, isNull);
      expect(msg.senderAvatarUrl, isNull);
    });

    test('fromJson defaults senderDisplayName to empty string when null', () {
      final json = messageJson();
      json['sender_display_name'] = null;
      final msg = Message.fromJson(json);
      expect(msg.senderDisplayName, '');
    });

    test('toJson roundtrip preserves all fields', () {
      final msg = Message.fromJson(messageJson(id: 'msg-2', body: 'Hey'));
      final roundtripped = Message.fromJson(msg.toJson());

      expect(roundtripped.id, msg.id);
      expect(roundtripped.body, msg.body);
      expect(roundtripped.senderDisplayName, msg.senderDisplayName);
    });
  });
}
