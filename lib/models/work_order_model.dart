import 'package:cloud_firestore/cloud_firestore.dart';

enum WorkOrderStatus {
  open,
  inProgress,
  completed,
  cancelled,
}

enum WorkOrderPriority {
  low,
  medium,
  high,
  urgent,
}

class WorkOrderComment {
  final String text;
  final String authorUid;
  final String authorName;
  final DateTime createdAt;

  const WorkOrderComment({
    required this.text,
    required this.authorUid,
    required this.authorName,
    required this.createdAt,
  });

  factory WorkOrderComment.fromFirestore(Map<String, dynamic> data) {
    return WorkOrderComment(
      text: data['text'] as String,
      authorUid: data['authorUid'] as String,
      authorName: data['authorName'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'text': text,
      'authorUid': authorUid,
      'authorName': authorName,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}

class WorkOrderModel {
  final String id;
  final String facilityId;
  final String title;
  final String? description;
  final String? unitId;
  final String? tenantId;
  final String? assignedTo; // User UID
  final WorkOrderStatus status;
  final WorkOrderPriority priority;
  final DateTime? dueDate;
  final List<WorkOrderComment> comments;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;

  const WorkOrderModel({
    required this.id,
    required this.facilityId,
    required this.title,
    this.description,
    this.unitId,
    this.tenantId,
    this.assignedTo,
    required this.status,
    required this.priority,
    this.dueDate,
    this.comments = const [],
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
  });

  factory WorkOrderModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final commentsList = data['comments'] as List<dynamic>? ?? [];
    return WorkOrderModel(
      id: doc.id,
      facilityId: data['facilityId'] as String,
      title: data['title'] as String,
      description: data['description'] as String?,
      unitId: data['unitId'] as String?,
      tenantId: data['tenantId'] as String?,
      assignedTo: data['assignedTo'] as String?,
      status: WorkOrderStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => WorkOrderStatus.open,
      ),
      priority: WorkOrderPriority.values.firstWhere(
        (e) => e.name == data['priority'],
        orElse: () => WorkOrderPriority.medium,
      ),
      dueDate: data['dueDate'] != null
          ? (data['dueDate'] as Timestamp).toDate()
          : null,
      comments: commentsList
          .map((c) => WorkOrderComment.fromFirestore(c as Map<String, dynamic>))
          .toList(),
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      createdBy: data['createdBy'] as String,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'title': title,
      if (description != null) 'description': description,
      if (unitId != null) 'unitId': unitId,
      if (tenantId != null) 'tenantId': tenantId,
      if (assignedTo != null) 'assignedTo': assignedTo,
      'status': status.name,
      'priority': priority.name,
      if (dueDate != null) 'dueDate': Timestamp.fromDate(dueDate!),
      'comments': comments.map((c) => c.toFirestore()).toList(),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdBy': createdBy,
    };
  }

  WorkOrderModel copyWith({
    String? id,
    String? facilityId,
    String? title,
    String? description,
    String? unitId,
    String? tenantId,
    String? assignedTo,
    WorkOrderStatus? status,
    WorkOrderPriority? priority,
    DateTime? dueDate,
    List<WorkOrderComment>? comments,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return WorkOrderModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      title: title ?? this.title,
      description: description ?? this.description,
      unitId: unitId ?? this.unitId,
      tenantId: tenantId ?? this.tenantId,
      assignedTo: assignedTo ?? this.assignedTo,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      dueDate: dueDate ?? this.dueDate,
      comments: comments ?? this.comments,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}

extension WorkOrderStatusExtension on WorkOrderStatus {
  String get displayName {
    switch (this) {
      case WorkOrderStatus.open:
        return 'Open';
      case WorkOrderStatus.inProgress:
        return 'In Progress';
      case WorkOrderStatus.completed:
        return 'Completed';
      case WorkOrderStatus.cancelled:
        return 'Cancelled';
    }
  }
}

extension WorkOrderPriorityExtension on WorkOrderPriority {
  String get displayName {
    switch (this) {
      case WorkOrderPriority.low:
        return 'Low';
      case WorkOrderPriority.medium:
        return 'Medium';
      case WorkOrderPriority.high:
        return 'High';
      case WorkOrderPriority.urgent:
        return 'Urgent';
    }
  }
}
