// Модели данных, соответствующие JSON backend'а CRM.

class AssignedUser {
  const AssignedUser({required this.id, required this.name});
  final String id;
  final String name;

  static AssignedUser? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return AssignedUser(id: j['id'] as String, name: j['name'] as String? ?? '');
  }
}

class ContactBrief {
  const ContactBrief({
    required this.id,
    required this.name,
    this.phone,
    this.chatId,
    this.avatarUri,
  });
  final String id;
  final String name;
  final String? phone;
  final String? chatId;
  final String? avatarUri;

  factory ContactBrief.fromJson(Map<String, dynamic> j) => ContactBrief(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        phone: j['phone'] as String?,
        chatId: j['chatId'] as String?,
        avatarUri: j['avatarUri'] as String?,
      );
}

class Conversation {
  Conversation({
    required this.id,
    required this.status,
    required this.unreadCount,
    required this.contact,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.channelId,
    this.assignedUser,
  });

  final String id;
  final String status;
  int unreadCount;
  final ContactBrief contact;
  DateTime? lastMessageAt;
  String? lastMessagePreview;
  final String? channelId;
  final AssignedUser? assignedUser;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        status: j['status'] as String? ?? 'open',
        unreadCount: (j['unreadCount'] as num?)?.toInt() ?? 0,
        contact: ContactBrief.fromJson(j['contact'] as Map<String, dynamic>),
        lastMessageAt: _parseDate(j['lastMessageAt']),
        lastMessagePreview: j['lastMessagePreview'] as String?,
        channelId: j['channelId'] as String?,
        assignedUser: AssignedUser.fromJson(j['assignedUser'] as Map<String, dynamic>?),
      );
}

class Attachment {
  const Attachment({required this.id, required this.kind, this.mimeType, this.status, this.storageKey});
  final String id;
  final String kind;
  final String? mimeType;
  final String? status;
  final String? storageKey;

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'unknown',
        mimeType: j['mimeType'] as String?,
        status: j['status'] as String?,
        storageKey: j['storageKey'] as String?,
      );
}

class Message {
  Message({
    required this.id,
    required this.direction,
    required this.type,
    required this.status,
    this.text,
    this.isEdited = false,
    this.deletedAt,
    this.displayHint,
    this.authorName,
    this.replyToMessageId,
    this.providerDateTime,
    required this.createdAt,
    this.attachments = const [],
  });

  final String id;
  final String direction; // inbound | outbound
  final String type;
  String status;
  String? text;
  bool isEdited;
  DateTime? deletedAt;
  String? displayHint;
  final String? authorName;
  final String? replyToMessageId;
  final DateTime? providerDateTime;
  final DateTime createdAt;
  final List<Attachment> attachments;

  bool get isOutbound => direction == 'outbound';
  bool get isDeleted => deletedAt != null;
  DateTime get sortTime => providerDateTime ?? createdAt;

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'] as String,
        direction: j['direction'] as String? ?? 'inbound',
        type: j['type'] as String? ?? 'text',
        status: j['status'] as String? ?? 'inbound',
        text: j['text'] as String?,
        isEdited: j['isEdited'] as bool? ?? false,
        deletedAt: _parseDate(j['deletedAt']),
        displayHint: j['displayHint'] as String?,
        authorName: j['authorName'] as String?,
        replyToMessageId: j['replyToMessageId'] as String?,
        providerDateTime: _parseDate(j['providerDateTime']),
        createdAt: _parseDate(j['createdAt']) ?? DateTime.now(),
        attachments: ((j['attachments'] as List<dynamic>?) ?? [])
            .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

DateTime? _parseDate(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toLocal();
  return null;
}
