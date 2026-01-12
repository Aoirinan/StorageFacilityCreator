import 'package:cloud_firestore/cloud_firestore.dart';

/// Model for SMS conversation between facility and tenant
class SMSConversationModel {
  final String id;
  final String facilityId;
  final String tenantId;
  final String phoneNumber; // Normalized phone number
  final String lastMessage; // Last message preview (truncated)
  final DateTime? lastMessageAt;
  final SMSDirection lastMessageDirection;
  final int unreadCount;
  final DateTime createdAt;
  final DateTime? updatedAt;

  SMSConversationModel({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.phoneNumber,
    required this.lastMessage,
    this.lastMessageAt,
    required this.lastMessageDirection,
    required this.unreadCount,
    required this.createdAt,
    this.updatedAt,
  });

  /// Create from Firestore document
  factory SMSConversationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    return SMSConversationModel(
      id: doc.id,
      facilityId: doc.reference.parent.parent?.id ?? '',
      tenantId: data?['tenantId'] ?? '',
      phoneNumber: data?['phoneNumber'] ?? '',
      lastMessage: data?['lastMessage'] ?? '',
      lastMessageAt: (data?['lastMessageAt'] as Timestamp?)?.toDate(),
      lastMessageDirection: _parseDirection(data?['lastMessageDirection']),
      unreadCount: data?['unreadCount'] ?? 0,
      createdAt: (data?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data?['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  /// Convert to Firestore map
  Map<String, dynamic> toFirestore() {
    return {
      'tenantId': tenantId,
      'phoneNumber': phoneNumber,
      'lastMessage': lastMessage,
      'lastMessageAt': lastMessageAt != null ? Timestamp.fromDate(lastMessageAt!) : null,
      'lastMessageDirection': lastMessageDirection.name,
      'unreadCount': unreadCount,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp(),
    };
  }

  /// Parse direction from string
  static SMSDirection _parseDirection(dynamic value) {
    if (value == null) return SMSDirection.incoming;
    if (value.toString().toLowerCase() == 'outgoing') return SMSDirection.outgoing;
    return SMSDirection.incoming;
  }

  /// Copy with method
  SMSConversationModel copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    String? phoneNumber,
    String? lastMessage,
    DateTime? lastMessageAt,
    SMSDirection? lastMessageDirection,
    int? unreadCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SMSConversationModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessageDirection: lastMessageDirection ?? this.lastMessageDirection,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// SMS message direction
enum SMSDirection {
  incoming,
  outgoing,
}

/// Extension for display names
extension SMSDirectionExtension on SMSDirection {
  String get displayName {
    switch (this) {
      case SMSDirection.incoming:
        return 'Incoming';
      case SMSDirection.outgoing:
        return 'Outgoing';
    }
  }

  bool get isIncoming => this == SMSDirection.incoming;
  bool get isOutgoing => this == SMSDirection.outgoing;
}

