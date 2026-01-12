import 'package:cloud_firestore/cloud_firestore.dart';
import 'reminder_model.dart';

/// Escalation step in a workflow
class EscalationStep {
  final int order; // Order in the escalation chain (1, 2, 3...)
  final ReminderChannel channel; // Channel to use for this step
  final int delayHours; // Hours to wait before this step
  final String? messageTemplate; // Optional custom message for this step
  final bool stopOnResponse; // Stop escalation if tenant responds

  const EscalationStep({
    required this.order,
    required this.channel,
    required this.delayHours,
    this.messageTemplate,
    this.stopOnResponse = true,
  });

  Map<String, dynamic> toMap() {
    return {
      'order': order,
      'channel': channel.name,
      'delayHours': delayHours,
      'messageTemplate': messageTemplate,
      'stopOnResponse': stopOnResponse,
    };
  }

  factory EscalationStep.fromMap(Map<String, dynamic> map) {
    return EscalationStep(
      order: map['order'] as int,
      channel: ReminderChannel.values.firstWhere(
        (c) => c.name == map['channel'],
        orElse: () => ReminderChannel.email,
      ),
      delayHours: map['delayHours'] as int,
      messageTemplate: map['messageTemplate'] as String?,
      stopOnResponse: map['stopOnResponse'] as bool? ?? true,
    );
  }
}

/// Escalation workflow definition
class EscalationWorkflow {
  final String id;
  final String facilityId;
  final String name;
  final String? description;
  final ReminderType triggerType; // What triggers this escalation
  final List<EscalationStep> steps;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;

  const EscalationWorkflow({
    required this.id,
    required this.facilityId,
    required this.name,
    this.description,
    required this.triggerType,
    required this.steps,
    this.isActive = true,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'name': name,
      'description': description,
      'triggerType': triggerType.name,
      'steps': steps.map((s) => s.toMap()).toList(),
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'createdBy': createdBy,
    };
  }

  factory EscalationWorkflow.fromMap(String id, Map<String, dynamic> map) {
    return EscalationWorkflow(
      id: id,
      facilityId: map['facilityId'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      triggerType: ReminderType.values.firstWhere(
        (t) => t.name == map['triggerType'],
        orElse: () => ReminderType.rentOverdue,
      ),
      steps: (map['steps'] as List<dynamic>?)
              ?.map((s) => EscalationStep.fromMap(s as Map<String, dynamic>))
              .toList() ??
          [],
      isActive: map['isActive'] as bool? ?? true,
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: map['createdBy'] as String,
    );
  }
}

/// Active escalation instance (tracking progress through workflow)
class EscalationInstance {
  final String id;
  final String facilityId;
  final String tenantId;
  final String workflowId;
  final ReminderType triggerType;
  final int currentStep;
  final DateTime startedAt;
  final DateTime? completedAt;
  final bool isActive;
  final Map<String, dynamic>? metadata;

  const EscalationInstance({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.workflowId,
    required this.triggerType,
    required this.currentStep,
    required this.startedAt,
    this.completedAt,
    this.isActive = true,
    this.metadata,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'tenantId': tenantId,
      'workflowId': workflowId,
      'triggerType': triggerType.name,
      'currentStep': currentStep,
      'startedAt': Timestamp.fromDate(startedAt),
      'completedAt': completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      'isActive': isActive,
      'metadata': metadata,
    };
  }

  factory EscalationInstance.fromMap(String id, Map<String, dynamic> map) {
    return EscalationInstance(
      id: id,
      facilityId: map['facilityId'] as String,
      tenantId: map['tenantId'] as String,
      workflowId: map['workflowId'] as String,
      triggerType: ReminderType.values.firstWhere(
        (t) => t.name == map['triggerType'],
        orElse: () => ReminderType.rentOverdue,
      ),
      currentStep: map['currentStep'] as int,
      startedAt: (map['startedAt'] as Timestamp).toDate(),
      completedAt: (map['completedAt'] as Timestamp?)?.toDate(),
      isActive: map['isActive'] as bool? ?? true,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

