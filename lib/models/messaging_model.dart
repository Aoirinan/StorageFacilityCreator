import 'package:cloud_firestore/cloud_firestore.dart';

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
  });

  factory ConversationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final isPrivate = data['isPrivate'] ?? false;
    final participantUidsList = data['participantUids'];
    final participantNamesMap = data['participantNames'];
    
    return ConversationModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      title: data['title'] ?? '',
      createdAt: (data['createdAt'] as Timestamp).toDate(),
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
    return MessageModel(
      id: doc.id,
      conversationId: data['conversationId'] ?? '',
      facilityId: data['facilityId'] ?? '',
      text: data['text'] ?? '',
      createdAt: (data['createdAt'] as Timestamp).toDate(),
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
