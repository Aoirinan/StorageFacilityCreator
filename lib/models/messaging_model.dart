import 'package:cloud_firestore/cloud_firestore.dart';

DateTime _dateTimeFromFirestoreField(dynamic value, {required DateTime ifMissing}) {
  if (value is Timestamp) return value.toDate();
  return ifMissing;
}

class ConversationModel {
  final String id;
  final String facilityId;
  final String title;
  final DateTime createdAt;
  final String createdByUid;
  final String createdByEmail;
  final String createdByName;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final bool isActive;
  
  // Private conversation fields (for 1-on-1 messaging)
  final bool isPrivate; // true for 1-on-1, false for group
  final List<String> participantUids; // For private conversations: [user1Uid, user2Uid]
  final Map<String, String>? participantNames; // uid -> displayName for participants
  /// uid -> email when known (optional; older docs may omit this)
  final Map<String, String>? participantEmails;

  const ConversationModel({
    required this.id,
    required this.facilityId,
    required this.title,
    required this.createdAt,
    required this.createdByUid,
    required this.createdByEmail,
    required this.createdByName,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.isActive = true,
    this.isPrivate = false,
    this.participantUids = const [],
    this.participantNames,
    this.participantEmails,
  });

  /// Placeholder / bad values stored for the other person in older data.
  static bool isWeakParticipantLabel(String? s) {
    if (s == null) return true;
    final t = s.trim().toLowerCase();
    if (t.isEmpty) return true;
    const weak = {'unknown', 'user', 'n/a', 'unknown email', 'none', 'teammate'};
    if (weak.contains(t)) return true;
    // Generic fallback label when profile data is missing (e.g. unreadable user doc)
    if (t.startsWith('teammate')) return true;
    return false;
  }

  factory ConversationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final isPrivate = data['isPrivate'] ?? false;
    final participantUidsList = data['participantUids'];
    final participantNamesMap = data['participantNames'];
    final participantEmailsMap = data['participantEmails'];

    return ConversationModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      title: data['title'] ?? '',
      createdAt: _dateTimeFromFirestoreField(
        data['createdAt'],
        ifMissing: DateTime.now(),
      ),
      createdByUid: data['createdByUid'] ?? '',
      createdByEmail: data['createdByEmail'] ?? '',
      createdByName: data['createdByName'] ?? '',
      lastMessageAt: data['lastMessageAt'] != null 
          ? (data['lastMessageAt'] as Timestamp).toDate()
          : null,
      lastMessagePreview: data['lastMessagePreview'],
      isActive: data['isActive'] ?? true,
      isPrivate: isPrivate,
      participantUids: participantUidsList != null 
          ? List<String>.from(participantUidsList)
          : [],
      participantNames: participantNamesMap != null
          ? Map<String, String>.from(participantNamesMap)
          : null,
      participantEmails: participantEmailsMap != null
          ? Map<String, String>.from(
              (participantEmailsMap as Map<dynamic, dynamic>).map(
                (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
              ),
            )
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'title': title,
      'createdAt': Timestamp.fromDate(createdAt),
      'createdByUid': createdByUid,
      'createdByEmail': createdByEmail,
      'createdByName': createdByName,
      'lastMessageAt': lastMessageAt != null ? Timestamp.fromDate(lastMessageAt!) : null,
      'lastMessagePreview': lastMessagePreview,
      'isActive': isActive,
      'isPrivate': isPrivate,
      'participantUids': participantUids,
      if (participantNames != null) 'participantNames': participantNames,
      if (participantEmails != null) 'participantEmails': participantEmails,
    };
  }

  ConversationModel copyWith({
    String? id,
    String? facilityId,
    String? title,
    DateTime? createdAt,
    String? createdByUid,
    String? createdByEmail,
    String? createdByName,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    bool? isActive,
    bool? isPrivate,
    List<String>? participantUids,
    Map<String, String>? participantNames,
    Map<String, String>? participantEmails,
  }) {
    return ConversationModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      createdByUid: createdByUid ?? this.createdByUid,
      createdByEmail: createdByEmail ?? this.createdByEmail,
      createdByName: createdByName ?? this.createdByName,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      isActive: isActive ?? this.isActive,
      isPrivate: isPrivate ?? this.isPrivate,
      participantUids: participantUids ?? this.participantUids,
      participantNames: participantNames ?? this.participantNames,
      participantEmails: participantEmails ?? this.participantEmails,
    );
  }
  
  // Helper: Get the other participant's name for private conversations
  String? getOtherParticipantName(String currentUserId) {
    if (!isPrivate || participantNames == null) return null;
    try {
      final otherUid = participantUids.firstWhere(
        (uid) => uid != currentUserId,
        orElse: () => '',
      );
      if (otherUid.isEmpty) return null;
      return participantNames![otherUid];
    } catch (e) {
      return null;
    }
  }
  
  // Helper: Get the other participant's UID for private conversations
  String? getOtherParticipantUid(String currentUserId) {
    if (!isPrivate) return null;
    try {
      return participantUids.firstWhere((uid) => uid != currentUserId);
    } catch (e) {
      return null;
    }
  }

  String? _otherParticipantEmail(String currentUserId) {
    final otherUid = getOtherParticipantUid(currentUserId);
    if (otherUid == null) return null;
    final e = participantEmails?[otherUid]?.trim();
    if (e == null || e.isEmpty) return null;
    return e;
  }

  /// Title for list + thread header: best available name, email, or a neutral label.
  /// [employeeChatNamesByUid] is optional facility-level nicknames (see `employeeChatNames`).
  String displayTitleForViewer(
    String currentUserId, {
    Map<String, String>? employeeChatNamesByUid,
  }) {
    if (!isPrivate) {
      final t = title.trim();
      return t.isNotEmpty ? t : 'Conversation';
    }
    final otherUid = getOtherParticipantUid(currentUserId);
    if (otherUid == null) {
      final t = title.trim();
      return t.isNotEmpty ? t : 'Direct message';
    }

    final chatName = employeeChatNamesByUid?[otherUid]?.trim();
    if (chatName != null && chatName.isNotEmpty) {
      return chatName;
    }

    final rawName = participantNames?[otherUid]?.trim();
    if (rawName != null &&
        rawName.isNotEmpty &&
        !isWeakParticipantLabel(rawName)) {
      return rawName;
    }

    final email = _otherParticipantEmail(currentUserId);
    if (email != null && email.contains('@')) {
      return email;
    }
    if (email != null && email.isNotEmpty) {
      return email;
    }

    final fallbackTitle = title.trim();
    if (fallbackTitle.isNotEmpty && !isWeakParticipantLabel(fallbackTitle)) {
      return fallbackTitle;
    }

    final tail = otherUid.length >= 6 ? otherUid.substring(otherUid.length - 6) : otherUid;
    return 'Teammate ($tail)';
  }
}

class MessageModel {
  final String id;
  final String conversationId;
  final String facilityId;
  final String text;
  final DateTime createdAt;
  final String senderUid;
  final String senderEmail;
  final String senderName;
  final Map<String, bool> readBy;
  final bool isActive;

  const MessageModel({
    required this.id,
    required this.conversationId,
    required this.facilityId,
    required this.text,
    required this.createdAt,
    required this.senderUid,
    required this.senderEmail,
    required this.senderName,
    this.readBy = const {},
    this.isActive = true,
  });

  factory MessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    // Server timestamps are null on the first local snapshot; avoid throwing so the stream
    // does not briefly flip to AsyncValue.error (red error screen) before the next event.
    final createdAt = _dateTimeFromFirestoreField(
      data['createdAt'],
      ifMissing: DateTime.now(),
    );
    return MessageModel(
      id: doc.id,
      conversationId: data['conversationId'] ?? '',
      facilityId: data['facilityId'] ?? '',
      text: data['text'] ?? '',
      createdAt: createdAt,
      senderUid: data['senderUid'] ?? '',
      senderEmail: data['senderEmail'] ?? '',
      senderName: data['senderName'] ?? '',
      readBy: data['readBy'] != null 
          ? Map<String, bool>.from(data['readBy'])
          : {},
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'conversationId': conversationId,
      'facilityId': facilityId,
      'text': text,
      'createdAt': Timestamp.fromDate(createdAt),
      'senderUid': senderUid,
      'senderEmail': senderEmail,
      'senderName': senderName,
      'readBy': readBy,
      'isActive': isActive,
    };
  }

  MessageModel copyWith({
    String? id,
    String? conversationId,
    String? facilityId,
    String? text,
    DateTime? createdAt,
    String? senderUid,
    String? senderEmail,
    String? senderName,
    Map<String, bool>? readBy,
    bool? isActive,
  }) {
    return MessageModel(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      facilityId: facilityId ?? this.facilityId,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      senderUid: senderUid ?? this.senderUid,
      senderEmail: senderEmail ?? this.senderEmail,
      senderName: senderName ?? this.senderName,
      readBy: readBy ?? this.readBy,
      isActive: isActive ?? this.isActive,
    );
  }

  // Helper getters
  bool get isRead => readBy.isNotEmpty;
  
  bool isReadBy(String uid) => readBy[uid] ?? false;
  
  String get timeDisplay {
    final now = DateTime.now();
    final difference = now.difference(createdAt);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${createdAt.month}/${createdAt.day}/${createdAt.year}';
    }
  }
}
