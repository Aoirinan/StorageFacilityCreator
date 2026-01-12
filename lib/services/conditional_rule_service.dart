import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/conditional_rule_model.dart';
import '../models/reminder_model.dart';

/// Service for managing conditional rules for automation
class ConditionalRuleService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a conditional rule
  static Future<String> createRule({
    required String facilityId,
    required String name,
    String? description,
    required ReminderType appliesTo,
    required List<Condition> conditions,
    required RuleAction action,
    Map<String, dynamic>? actionParams,
    int priority = 0,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final rule = ConditionalRule(
        id: '',
        facilityId: facilityId,
        name: name,
        description: description,
        appliesTo: appliesTo,
        conditions: conditions,
        action: action,
        actionParams: actionParams,
        priority: priority,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conditionalRules')
          .add(rule.toMap());

      if (kDebugMode) {
        print('✅ [ConditionalRule] Created rule: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ConditionalRule] Error creating rule: $e');
      }
      rethrow;
    }
  }

  /// Get all conditional rules for a facility
  static Future<List<ConditionalRule>> getRulesForFacility(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conditionalRules')
          .where('isActive', isEqualTo: true)
          .orderBy('priority', descending: true)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => ConditionalRule.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ConditionalRule] Error getting rules: $e');
      }
      return [];
    }
  }

  /// Update a conditional rule
  static Future<void> updateRule({
    required String facilityId,
    required String ruleId,
    String? name,
    String? description,
    ReminderType? appliesTo,
    List<Condition>? conditions,
    RuleAction? action,
    Map<String, dynamic>? actionParams,
    int? priority,
    bool? isActive,
  }) async {
    try {
      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updates['name'] = name;
      if (description != null) updates['description'] = description;
      if (appliesTo != null) updates['appliesTo'] = appliesTo.name;
      if (conditions != null) updates['conditions'] = conditions.map((c) => c.toMap()).toList();
      if (action != null) updates['action'] = action.name;
      if (actionParams != null) updates['actionParams'] = actionParams;
      if (priority != null) updates['priority'] = priority;
      if (isActive != null) updates['isActive'] = isActive;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conditionalRules')
          .doc(ruleId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [ConditionalRule] Updated rule: $ruleId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ConditionalRule] Error updating rule: $e');
      }
      rethrow;
    }
  }

  /// Delete a conditional rule (soft delete)
  static Future<void> deleteRule({
    required String facilityId,
    required String ruleId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conditionalRules')
          .doc(ruleId)
          .update({'isActive': false});

      if (kDebugMode) {
        print('✅ [ConditionalRule] Deleted rule: $ruleId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ConditionalRule] Error deleting rule: $e');
      }
      rethrow;
    }
  }

  /// Evaluate conditional rules for a reminder type and tenant data
  /// Returns the first matching rule (highest priority)
  static Future<ConditionalRule?> evaluateRules({
    required String facilityId,
    required ReminderType reminderType,
    required Map<String, dynamic> tenantData,
  }) async {
    try {
      final rules = await getRulesForFacility(facilityId);
      
      // Filter rules that apply to this reminder type
      final applicableRules = rules.where((r) => r.appliesTo == reminderType).toList();
      
      // Evaluate each rule (already sorted by priority)
      for (final rule in applicableRules) {
        if (rule.evaluate(tenantData)) {
          return rule;
        }
      }
      
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ConditionalRule] Error evaluating rules: $e');
      }
      return null;
    }
  }
}

