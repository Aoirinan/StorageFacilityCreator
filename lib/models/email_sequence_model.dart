import 'package:cloud_firestore/cloud_firestore.dart';

/// Email sequence step (individual email in the sequence)
class EmailSequenceStep {
  final int order; // Order in sequence (1, 2, 3...)
  final String? emailTemplateId; // Reference to email template
  final String subject; // Email subject
  final String htmlBody; // Email HTML body
  final String? textBody; // Optional plain text version
  final int delayDays; // Days to wait after previous step (or trigger)
  final String? delayTime; // Optional time of day (HH:mm) to send
  final Map<String, dynamic>? metadata;

  const EmailSequenceStep({
    required this.order,
    this.emailTemplateId,
    required this.subject,
    required this.htmlBody,
    this.textBody,
    required this.delayDays,
    this.delayTime,
    this.metadata,
  });

  Map<String, dynamic> toMap() {
    return {
      'order': order,
      'emailTemplateId': emailTemplateId,
      'subject': subject,
      'htmlBody': htmlBody,
      'textBody': textBody,
      'delayDays': delayDays,
      'delayTime': delayTime,
      'metadata': metadata,
    };
  }

  factory EmailSequenceStep.fromMap(Map<String, dynamic> map) {
    return EmailSequenceStep(
      order: map['order'] as int,
      emailTemplateId: map['emailTemplateId'] as String?,
      subject: map['subject'] as String,
      htmlBody: map['htmlBody'] as String,
      textBody: map['textBody'] as String?,
      delayDays: map['delayDays'] as int,
      delayTime: map['delayTime'] as String?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Email sequence trigger type
enum SequenceTriggerType {
  tenantCreated, // When tenant is created
  moveInCompleted, // When move-in is completed
  contractSigned, // When contract is signed
  paymentReceived, // When first payment received
  manualStart, // Manually triggered
  custom, // Custom trigger based on conditions
}

/// Email sequence status
enum SequenceStatus {
  active,
  paused,
  completed,
  cancelled,
}

/// Email sequence definition
class EmailSequence {
  final String id;
  final String facilityId;
  final String name;
  final String? description;
  final SequenceTriggerType triggerType;
  final List<EmailSequenceStep> steps;
  final bool isActive;
  final SequenceStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final Map<String, dynamic>? conditions; // Trigger conditions

  const EmailSequence({
    required this.id,
    required this.facilityId,
    required this.name,
    this.description,
    required this.triggerType,
    required this.steps,
    this.isActive = true,
    this.status = SequenceStatus.active,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
    this.conditions,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'name': name,
      'description': description,
      'triggerType': triggerType.name,
      'steps': steps.map((s) => s.toMap()).toList(),
      'isActive': isActive,
      'status': status.name,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'createdBy': createdBy,
      'conditions': conditions,
    };
  }

  factory EmailSequence.fromMap(String id, Map<String, dynamic> map) {
    return EmailSequence(
      id: id,
      facilityId: map['facilityId'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      triggerType: SequenceTriggerType.values.firstWhere(
        (t) => t.name == map['triggerType'],
        orElse: () => SequenceTriggerType.manualStart,
      ),
      steps: (map['steps'] as List<dynamic>?)
              ?.map((s) => EmailSequenceStep.fromMap(s as Map<String, dynamic>))
              .toList() ??
          [],
      isActive: map['isActive'] as bool? ?? true,
      status: SequenceStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => SequenceStatus.active,
      ),
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: map['createdBy'] as String,
      conditions: map['conditions'] as Map<String, dynamic>?,
    );
  }
}

/// Active email sequence instance (tracking progress through sequence)
class EmailSequenceInstance {
  final String id;
  final String facilityId;
  final String tenantId;
  final String sequenceId;
  final SequenceTriggerType triggerType;
  final int currentStep;
  final DateTime startedAt;
  final DateTime? completedAt;
  final SequenceStatus status;
  final Map<String, dynamic>? metadata;

  const EmailSequenceInstance({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.sequenceId,
    required this.triggerType,
    required this.currentStep,
    required this.startedAt,
    this.completedAt,
    this.status = SequenceStatus.active,
    this.metadata,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'tenantId': tenantId,
      'sequenceId': sequenceId,
      'triggerType': triggerType.name,
      'currentStep': currentStep,
      'startedAt': Timestamp.fromDate(startedAt),
      'completedAt': completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      'status': status.name,
      'metadata': metadata,
    };
  }

  factory EmailSequenceInstance.fromMap(String id, Map<String, dynamic> map) {
    return EmailSequenceInstance(
      id: id,
      facilityId: map['facilityId'] as String,
      tenantId: map['tenantId'] as String,
      sequenceId: map['sequenceId'] as String,
      triggerType: SequenceTriggerType.values.firstWhere(
        (t) => t.name == map['triggerType'],
        orElse: () => SequenceTriggerType.manualStart,
      ),
      currentStep: map['currentStep'] as int,
      startedAt: (map['startedAt'] as Timestamp).toDate(),
      completedAt: (map['completedAt'] as Timestamp?)?.toDate(),
      status: SequenceStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => SequenceStatus.active,
      ),
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Email sequence delivery record
class EmailSequenceDelivery {
  final String id;
  final String instanceId;
  final int stepOrder;
  final String tenantId;
  final String facilityId;
  final String subject;
  final DateTime sentAt;
  final bool success;
  final String? errorMessage;
  final String? messageId; // Email service message ID

  const EmailSequenceDelivery({
    required this.id,
    required this.instanceId,
    required this.stepOrder,
    required this.tenantId,
    required this.facilityId,
    required this.subject,
    required this.sentAt,
    required this.success,
    this.errorMessage,
    this.messageId,
  });

  Map<String, dynamic> toMap() {
    return {
      'instanceId': instanceId,
      'stepOrder': stepOrder,
      'tenantId': tenantId,
      'facilityId': facilityId,
      'subject': subject,
      'sentAt': Timestamp.fromDate(sentAt),
      'success': success,
      'errorMessage': errorMessage,
      'messageId': messageId,
    };
  }

  factory EmailSequenceDelivery.fromMap(String id, Map<String, dynamic> map) {
    return EmailSequenceDelivery(
      id: id,
      instanceId: map['instanceId'] as String,
      stepOrder: map['stepOrder'] as int,
      tenantId: map['tenantId'] as String,
      facilityId: map['facilityId'] as String,
      subject: map['subject'] as String,
      sentAt: (map['sentAt'] as Timestamp).toDate(),
      success: map['success'] as bool,
      errorMessage: map['errorMessage'] as String?,
      messageId: map['messageId'] as String?,
    );
  }
}

