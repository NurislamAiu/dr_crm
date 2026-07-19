import 'package:flutter_test/flutter_test.dart';

import 'package:crm/src/models/models.dart';

void main() {
  test('Conversation.fromJson парсит поля и контакт', () {
    final c = Conversation.fromJson({
      'id': 'conv-1',
      'status': 'open',
      'unreadCount': 3,
      'lastMessageAt': '2026-07-19T14:00:00.000Z',
      'lastMessagePreview': 'Привет',
      'channelId': 'chan-1',
      'assignedUser': {'id': 'u1', 'name': 'Алия'},
      'contact': {'id': 'ct1', 'name': 'Айгуль', 'phone': '77011234567', 'chatId': '77011234567'},
    });
    expect(c.id, 'conv-1');
    expect(c.unreadCount, 3);
    expect(c.contact.name, 'Айгуль');
    expect(c.assignedUser?.name, 'Алия');
    expect(c.lastMessageAt, isNotNull);
  });

  test('Message.fromJson: направление, редактирование, вложения', () {
    final m = Message.fromJson({
      'id': 'm1',
      'direction': 'outbound',
      'type': 'text',
      'status': 'delivered',
      'text': 'Ответ',
      'isEdited': true,
      'deletedAt': null,
      'createdAt': '2026-07-19T14:01:00.000Z',
      'attachments': [
        {'id': 'a1', 'kind': 'image', 'mimeType': 'image/jpeg', 'status': 'stored'}
      ],
    });
    expect(m.isOutbound, true);
    expect(m.isDeleted, false);
    expect(m.isEdited, true);
    expect(m.attachments.single.kind, 'image');
  });

  test('Message.fromJson: удалённое сообщение', () {
    final m = Message.fromJson({
      'id': 'm2',
      'direction': 'inbound',
      'type': 'text',
      'status': 'inbound',
      'deletedAt': '2026-07-19T14:02:00.000Z',
      'createdAt': '2026-07-19T14:01:00.000Z',
    });
    expect(m.isDeleted, true);
  });
}
