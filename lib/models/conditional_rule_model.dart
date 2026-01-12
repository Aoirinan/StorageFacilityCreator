import 'package:cloud_firestore/cloud_firestore.dart';
import 'reminder_model.dart';

/// Condition operator for rules
enum ConditionOperator {
  equals,
  notEquals,
  greaterThan,
  lessThan,
  contains,
  isEmpty,
  isNotEmpty,
  inList,
}

/// Condition in a rule
class Condition {
  final String field; // Field to check (e.g., 'daysLate', 'balance', 'leadSource')
  final ConditionOperator operator;
  final dynamic value; // Value to compare against

  const Condition({
    required this.field,
    required this.operator,
    this.value,
  });

  Map<String, dynamic> toMap() {
    return {
      'field': field,
      'operator': operator.name,
      'value': value,
    };
  }

  factory Condition.fromMap(Map<String, dynamic> map) {
    return Condition(
      field: map['field'] as String,
      operator: ConditionOperator.values.firstWhere(
        (op) => op.name == map['operator'],
        orElse: () => ConditionOperator.equals,
      ),
      value: map['value'],
    );
  }

  /// Evaluate condition against data
  bool evaluate(Map<String, dynamic> data) {
    final fieldValue = data[field];

    switch (operator) {
      case ConditionOperator.equals:
        return fieldValue == value;
      case ConditionOperator.notEquals:
        return fieldValue != value;
      case ConditionOperator.greaterThan:
        if (fieldValue is num && value is num) {
          return fieldValue > value;
        }
        return false;
      case ConditionOperator.lessThan:
        if (fieldValue is num && value is num) {
          return fieldValue < value;
        }
        return false;
      case ConditionOperator.contains:
        if (fieldValue is String && value is String) {
          return fieldValue.toLowerCase().contains(value.toLowerCase());
        }
        return false;
      case ConditionOperator.isEmpty:
        return fieldValue == null || fieldValue.toString().isEmpty;
      case ConditionOperator.isNotEmpty:
        return fieldValue != null && fieldValue.toString().isNotEmpty;
      case ConditionOperator.inList:
        if (value is List) {
          return value.contains(fieldValue);
        }
        return false;
    }
  }
}

/// Action to take when condition is met
enum RuleAction {
  sendReminder,
  sendEscalation,
  skipReminder,
  changeChannel,
  addTag,
  notifyStaff,
}

/// Conditional rule for reminders
class ConditionalRule {
  final String id;
  final String facilityId;
  final String name;
  final String? description;
  final ReminderType appliesTo; // Which reminder type this rule applies to
  final List<Condition> conditions; // All conditions must be true (AND logic)
  final RuleAction action;
  final Map<String, dynamic>? actionParams; // Parameters for the action
  final int priority; // Higher priority rules are evaluated first
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;

  const ConditionalRule({
    required this.id,
    required this.facilityId,
    required this.name,
    this.description,
    required this.appliesTo,
    required this.conditions,
    required this.action,
    this.actionParams,
    this.priority = 0,
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
      'appliesTo': appliesTo.name,
      'conditions': conditions.map((c) => c.toMap()).toList(),
      'action': action.name,
      'actionParams': actionParams,
      'priority': priority,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'createdBy': createdBy,
    };
  }

  factory ConditionalRule.fromMap(String id, Map<String, dynamic> map) {
    return ConditionalRule(
      id: id,
      facilityId: map['facilityId'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      appliesTo: ReminderType.values.firstWhere(
        (t) => t.name == map['appliesTo'],
        orElse: () => ReminderType.custom,
      ),
      conditions: (map['conditions'] as List<dynamic>?)
              ?.map((c) => Condition.fromMap(c as Map<String, dynamic>))
              .toList() ??
          [],
      action: RuleAction.values.firstWhere(
        (a) => a.name == map['action'],
        orElse: () => RuleAction.sendReminder,
      ),
      actionParams: map['actionParams'] as Map<String, dynamic>?,
      priority: map['priority'] as int? ?? 0,
      isActive: map['isActive'] as bool? ?? true,
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: map['createdBy'] as String,
    );
  }

  /// Check if all conditions are met
  bool evaluate(Map<String, dynamic> data) {
    if (conditions.isEmpty) return true;
    return conditions.every((condition) => condition.evaluate(data));
  }
}

