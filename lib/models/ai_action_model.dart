import 'package:cloud_firestore/cloud_firestore.dart';

enum AIActionType {
  createTenant,
  createPayment,
  sendMessage,
  createReminder,
  updateTenant,
  createContract,
  // Add more action types as needed
}

class AIAction {
  final AIActionType type;
  final String description;
  final Map<String, dynamic> parameters;
  final String estimatedImpact;
  final bool requiresConfirmation;

  const AIAction({
    required this.type,
    required this.description,
    required this.parameters,
    required this.estimatedImpact,
    this.requiresConfirmation = true,
  });

  factory AIAction.fromMap(Map<String, dynamic> map) {
    return AIAction(
      type: AIActionType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => AIActionType.createTenant,
      ),
      description: map['description'] as String,
      parameters: Map<String, dynamic>.from(map['parameters'] as Map? ?? {}),
      estimatedImpact: map['estimatedImpact'] as String? ?? '',
      requiresConfirmation: map['requiresConfirmation'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'description': description,
      'parameters': parameters,
      'estimatedImpact': estimatedImpact,
      'requiresConfirmation': requiresConfirmation,
    };
  }
}

class AIMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  final List<AIAction>? actions;
  final AIAction? confirmedAction;
  final DateTime? executedAt;
  final DateTime timestamp;

  const AIMessage({
    required this.role,
    required this.content,
    this.actions,
    this.confirmedAction,
    this.executedAt,
    required this.timestamp,
  });

  factory AIMessage.fromMap(Map<String, dynamic> map) {
    return AIMessage(
      role: map['role'] as String,
      content: map['content'] as String,
      actions: map['actions'] != null
          ? (map['actions'] as List)
              .map((a) => AIAction.fromMap(a as Map<String, dynamic>))
              .toList()
          : null,
      confirmedAction: map['confirmedAction'] != null
          ? AIAction.fromMap(map['confirmedAction'] as Map<String, dynamic>)
          : null,
      executedAt: map['executedAt'] != null
          ? (map['executedAt'] as Timestamp).toDate()
          : null,
      timestamp: (map['timestamp'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'content': content,
      if (actions != null)
        'actions': actions!.map((a) => a.toMap()).toList(),
      if (confirmedAction != null) 'confirmedAction': confirmedAction!.toMap(),
      if (executedAt != null) 'executedAt': Timestamp.fromDate(executedAt!),
      'timestamp': Timestamp.fromDate(timestamp),
    };
  }
}

class AIConversation {
  final String id;
  final String facilityId;
  final List<AIMessage> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AIConversation({
    required this.id,
    required this.facilityId,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AIConversation.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final messagesList = data['messages'] as List<dynamic>? ?? [];
    return AIConversation(
      id: doc.id,
      facilityId: data['facilityId'] as String,
      messages: messagesList
          .map((m) => AIMessage.fromMap(m as Map<String, dynamic>))
          .toList(),
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'messages': messages.map((m) => m.toMap()).toList(),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }
}

extension AIActionTypeExtension on AIActionType {
  String get displayName {
    switch (this) {
      case AIActionType.createTenant:
        return 'Create Tenant';
      case AIActionType.createPayment:
        return 'Create Payment';
      case AIActionType.sendMessage:
        return 'Send Message';
      case AIActionType.createReminder:
        return 'Create Reminder';
      case AIActionType.updateTenant:
        return 'Update Tenant';
      case AIActionType.createContract:
        return 'Create Contract';
    }
  }
}
