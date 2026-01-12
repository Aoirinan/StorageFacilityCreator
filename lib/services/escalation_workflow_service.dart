import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/escalation_workflow_model.dart';
import '../models/reminder_model.dart';
import '../services/reminder_service.dart';
import '../services/email_cloud_service.dart';
import '../services/sms_service.dart';
import '../services/template_integration_service.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';

/// Service for managing escalation workflows
class EscalationWorkflowService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create an escalation workflow
  static Future<String> createWorkflow({
    required String facilityId,
    required String name,
    String? description,
    required ReminderType triggerType,
    required List<EscalationStep> steps,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final workflow = EscalationWorkflow(
        id: '',
        facilityId: facilityId,
        name: name,
        description: description,
        triggerType: triggerType,
        steps: steps,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationWorkflows')
          .add(workflow.toMap());

      if (kDebugMode) {
        print('✅ [EscalationWorkflow] Created workflow: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error creating workflow: $e');
      }
      rethrow;
    }
  }

  /// Get all workflows for a facility
  static Future<List<EscalationWorkflow>> getWorkflowsForFacility(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationWorkflows')
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => EscalationWorkflow.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error getting workflows: $e');
      }
      return [];
    }
  }

  /// Start an escalation workflow for a tenant
  static Future<String> startEscalation({
    required String facilityId,
    required String tenantId,
    required String workflowId,
    required ReminderType triggerType,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final instance = EscalationInstance(
        id: '',
        facilityId: facilityId,
        tenantId: tenantId,
        workflowId: workflowId,
        triggerType: triggerType,
        currentStep: 0,
        startedAt: DateTime.now(),
        metadata: metadata,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationInstances')
          .add(instance.toMap());

      // Execute first step immediately
      await _executeEscalationStep(docRef.id, facilityId, tenantId, workflowId, 0);

      if (kDebugMode) {
        print('✅ [EscalationWorkflow] Started escalation: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error starting escalation: $e');
      }
      rethrow;
    }
  }

  /// Execute a specific step in an escalation workflow
  static Future<void> _executeEscalationStep(
    String instanceId,
    String facilityId,
    String tenantId,
    String workflowId,
    int stepIndex,
  ) async {
    try {
      // Get workflow
      final workflowDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationWorkflows')
          .doc(workflowId)
          .get();

      if (!workflowDoc.exists) {
        throw Exception('Workflow not found');
      }

      final workflow = EscalationWorkflow.fromMap(workflowId, workflowDoc.data()!);

      if (stepIndex >= workflow.steps.length) {
        // Escalation complete
        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('escalationInstances')
            .doc(instanceId)
            .update({
          'isActive': false,
          'completedAt': FieldValue.serverTimestamp(),
        });
        return;
      }

      final step = workflow.steps[stepIndex];

      // Get tenant info
      final tenantDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .get();

      if (!tenantDoc.exists) {
        throw Exception('Tenant not found');
      }

      // Get tenant and facility models for language-aware templates
      final tenant = TenantModel.fromFirestore(tenantDoc);
      final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
      final facility = facilityDoc.exists ? FacilityModel.fromFirestore(facilityDoc) : null;
      
      final tenantEmail = tenant.email;
      final tenantPhone = tenant.phone;
      
      // Extract language code from tenant's preferredLocale or facility's defaultLocale
      String? languageCode = TemplateIntegrationService.extractLanguageCode(
        tenant.preferredLocale ?? facility?.defaultLocale,
      );

      // Send reminder via appropriate channel
      switch (step.channel) {
        case ReminderChannel.email:
          if (tenantEmail != null && tenantEmail.isNotEmpty) {
            // Try to use language-aware template
            String? html;
            String? text;
            String? subject;
            
            // Prepare template variables
            final vars = <String, String>{
              'tenantName': tenant.name,
              'facilityName': facility?.name ?? 'Property Management',
              'message': step.messageTemplate ?? 'This is an automated reminder.',
            };
            
            // Try to get language-aware template for escalation
            final templateResult = await TemplateIntegrationService.getEmailTemplate(
              category: 'escalation', // Use 'escalation' category
              facilityId: facilityId,
              variables: vars,
              language: languageCode,
            );
            
            if (templateResult != null) {
              html = templateResult.htmlBody;
              text = templateResult.textBody;
              subject = templateResult.subject;
              
              if (kDebugMode) {
                print('✅ [EscalationWorkflow] Using language-aware template (language: ${languageCode ?? "default"})');
              }
            } else {
              // Fallback to step message template or default
              html = step.messageTemplate ?? 'This is an automated reminder.';
              text = step.messageTemplate ?? 'This is an automated reminder.';
              subject = 'Important Notice from ${facility?.name ?? "Property Management"}';
            }
            
            await EmailCloudService.sendEmail(
              facilityId: facilityId,
              to: tenantEmail,
              subject: subject,
              html: html,
              text: text,
            );
          }
          break;
        case ReminderChannel.sms:
          if (tenantPhone != null && tenantPhone.isNotEmpty) {
            // Try to use language-aware SMS template
            String? smsMessage = step.messageTemplate ?? 'This is an automated reminder.';
            
            // Prepare template variables
            final vars = <String, String>{
              'tenantName': tenant.name,
              'facilityName': facility?.name ?? 'Property Management',
              'message': step.messageTemplate ?? 'This is an automated reminder.',
            };
            
            // Try to get language-aware SMS template
            final templateResult = await TemplateIntegrationService.getSMSTemplate(
              category: 'escalation',
              facilityId: facilityId,
              variables: vars,
              language: languageCode,
            );
            
            if (templateResult != null) {
              smsMessage = templateResult.message;
              if (kDebugMode) {
                print('✅ [EscalationWorkflow] Using language-aware SMS template (language: ${languageCode ?? "default"})');
              }
            }
            
            await SMSService.sendSMS(
              facilityId: facilityId,
              to: tenantPhone,
              message: smsMessage,
            );
          }
          break;
        case ReminderChannel.push:
        case ReminderChannel.inApp:
          // Create in-app reminder
          await ReminderService.createReminder(
            tenantId: tenantId,
            facilityId: facilityId,
            type: workflow.triggerType,
            channels: [step.channel],
            title: 'Important Notice',
            message: step.messageTemplate ?? 'This is an automated reminder.',
            scheduledFor: DateTime.now(),
            tenantEmail: tenantEmail,
            tenantPhone: tenantPhone,
            metadata: {
              'escalationInstanceId': instanceId,
              'escalationStep': stepIndex,
            },
          );
          break;
      }

      // Schedule next step if there is one
      if (stepIndex + 1 < workflow.steps.length) {
        final nextStep = workflow.steps[stepIndex + 1];
        final nextStepTime = DateTime.now().add(Duration(hours: nextStep.delayHours));

        // Update instance to next step
        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('escalationInstances')
            .doc(instanceId)
            .update({
          'currentStep': stepIndex + 1,
          'nextStepTime': Timestamp.fromDate(nextStepTime),
        });

        // Schedule Cloud Function or use scheduled task to execute next step
        // For now, we'll rely on a scheduled job to check and execute pending steps
      } else {
        // No more steps - mark as complete
        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('escalationInstances')
            .doc(instanceId)
            .update({
          'isActive': false,
          'completedAt': FieldValue.serverTimestamp(),
        });
      }

      if (kDebugMode) {
        print('✅ [EscalationWorkflow] Executed step $stepIndex for instance $instanceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error executing step: $e');
      }
      rethrow;
    }
  }

  /// Process pending escalation steps (called by scheduled job)
  static Future<void> processPendingSteps(String facilityId) async {
    try {
      final now = DateTime.now();
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationInstances')
          .where('isActive', isEqualTo: true)
          .where('nextStepTime', isLessThanOrEqualTo: Timestamp.fromDate(now))
          .get();

      for (final doc in snapshot.docs) {
        final instance = EscalationInstance.fromMap(doc.id, doc.data());
        await _executeEscalationStep(
          instance.id,
          instance.facilityId,
          instance.tenantId,
          instance.workflowId,
          instance.currentStep,
        );
      }

      if (kDebugMode) {
        print('✅ [EscalationWorkflow] Processed ${snapshot.docs.length} pending steps');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error processing pending steps: $e');
      }
    }
  }

  /// Stop an escalation (e.g., if tenant responds)
  static Future<void> stopEscalation({
    required String facilityId,
    required String instanceId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationInstances')
          .doc(instanceId)
          .update({
        'isActive': false,
        'completedAt': FieldValue.serverTimestamp(),
        'stoppedReason': 'tenant_response',
      });

      if (kDebugMode) {
        print('✅ [EscalationWorkflow] Stopped escalation: $instanceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error stopping escalation: $e');
      }
      rethrow;
    }
  }

  /// Update an escalation workflow
  static Future<void> updateWorkflow({
    required String facilityId,
    required String workflowId,
    String? name,
    String? description,
    ReminderType? triggerType,
    List<EscalationStep>? steps,
    bool? isActive,
  }) async {
    try {
      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updates['name'] = name;
      if (description != null) updates['description'] = description;
      if (triggerType != null) updates['triggerType'] = triggerType.name;
      if (steps != null) updates['steps'] = steps.map((s) => s.toMap()).toList();
      if (isActive != null) updates['isActive'] = isActive;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationWorkflows')
          .doc(workflowId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [EscalationWorkflow] Updated workflow: $workflowId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error updating workflow: $e');
      }
      rethrow;
    }
  }

  /// Delete an escalation workflow (soft delete by setting isActive to false)
  static Future<void> deleteWorkflow({
    required String facilityId,
    required String workflowId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('escalationWorkflows')
          .doc(workflowId)
          .update({'isActive': false});

      if (kDebugMode) {
        print('✅ [EscalationWorkflow] Deleted workflow: $workflowId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EscalationWorkflow] Error deleting workflow: $e');
      }
      rethrow;
    }
  }
}

