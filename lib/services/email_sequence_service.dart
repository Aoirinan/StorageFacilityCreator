import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/email_sequence_model.dart';
import '../services/email_cloud_service.dart';
import '../services/template_integration_service.dart';
import '../services/tenant_service.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';

/// Service for managing email sequences (drip campaigns)
class EmailSequenceService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create an email sequence
  static Future<String> createEmailSequence({
    required String facilityId,
    required String name,
    String? description,
    required SequenceTriggerType triggerType,
    required List<EmailSequenceStep> steps,
    Map<String, dynamic>? conditions,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final sequence = EmailSequence(
        id: '',
        facilityId: facilityId,
        name: name,
        description: description,
        triggerType: triggerType,
        steps: steps,
        createdAt: DateTime.now(),
        createdBy: user.uid,
        conditions: conditions,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequences')
          .add(sequence.toMap());

      if (kDebugMode) {
        print('✅ [EmailSequence] Created sequence: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error creating sequence: $e');
      }
      rethrow;
    }
  }

  /// Update an email sequence
  static Future<void> updateEmailSequence({
    required String facilityId,
    required String sequenceId,
    String? name,
    String? description,
    SequenceTriggerType? triggerType,
    List<EmailSequenceStep>? steps,
    Map<String, dynamic>? conditions,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updates['name'] = name;
      if (description != null) updates['description'] = description;
      if (triggerType != null) updates['triggerType'] = triggerType.name;
      if (steps != null) updates['steps'] = steps.map((s) => s.toMap()).toList();
      if (conditions != null) updates['conditions'] = conditions;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequences')
          .doc(sequenceId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [EmailSequence] Updated sequence: $sequenceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error updating sequence: $e');
      }
      rethrow;
    }
  }

  /// Get email sequences for a facility
  static Future<List<EmailSequence>> getEmailSequences(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequences')
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => EmailSequence.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error getting sequences: $e');
      }
      return [];
    }
  }

  /// Start an email sequence for a tenant
  static Future<String> startSequence({
    required String facilityId,
    required String tenantId,
    required String sequenceId,
    SequenceTriggerType? triggerType,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final sequenceDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequences')
          .doc(sequenceId)
          .get();

      if (!sequenceDoc.exists) {
        throw Exception('Email sequence not found');
      }

      final sequence = EmailSequence.fromMap(sequenceId, sequenceDoc.data()!);

      if (!sequence.isActive || sequence.status != SequenceStatus.active) {
        throw Exception('Email sequence is not active');
      }

      final instance = EmailSequenceInstance(
        id: '',
        facilityId: facilityId,
        tenantId: tenantId,
        sequenceId: sequenceId,
        triggerType: triggerType ?? sequence.triggerType,
        currentStep: 0,
        startedAt: DateTime.now(),
        metadata: metadata,
      );

      final instanceRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequenceInstances')
          .add(instance.toMap());

      // Schedule first step
      await _scheduleNextStep(instanceRef.id, facilityId, tenantId, sequence, 0);

      if (kDebugMode) {
        print('✅ [EmailSequence] Started sequence instance: ${instanceRef.id}');
      }

      return instanceRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error starting sequence: $e');
      }
      rethrow;
    }
  }

  /// Schedule the next step in a sequence
  static Future<void> _scheduleNextStep(
    String instanceId,
    String facilityId,
    String tenantId,
    EmailSequence sequence,
    int stepIndex,
  ) async {
    if (stepIndex >= sequence.steps.length) {
      // Sequence complete
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequenceInstances')
          .doc(instanceId)
          .update({
        'status': SequenceStatus.completed.name,
        'completedAt': FieldValue.serverTimestamp(),
        'currentStep': stepIndex,
      });
      return;
    }

    final step = sequence.steps[stepIndex];
    final delayDuration = Duration(days: step.delayDays);

    // Calculate send time
    DateTime sendTime = DateTime.now().add(delayDuration);
    if (step.delayTime != null) {
      final timeParts = step.delayTime!.split(':');
      if (timeParts.length == 2) {
        final hour = int.tryParse(timeParts[0]) ?? 9;
        final minute = int.tryParse(timeParts[1]) ?? 0;
        sendTime = DateTime(
          sendTime.year,
          sendTime.month,
          sendTime.day,
          hour,
          minute,
        );
      }
    }

    // Store scheduled step
    await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('emailSequenceInstances')
        .doc(instanceId)
        .collection('scheduledSteps')
        .add({
      'stepOrder': step.order,
      'scheduledFor': Timestamp.fromDate(sendTime),
      'subject': step.subject,
      'htmlBody': step.htmlBody,
      'textBody': step.textBody,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Process pending email sequence steps (called by scheduled job)
  static Future<void> processPendingSteps(String facilityId) async {
    try {
      final now = DateTime.now();
      
      // Find all active instances
      final instancesSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequenceInstances')
          .where('status', isEqualTo: SequenceStatus.active.name)
          .get();

      for (final instanceDoc in instancesSnapshot.docs) {
        final instance = EmailSequenceInstance.fromMap(instanceDoc.id, instanceDoc.data());

        // Get scheduled steps for this instance
        final scheduledStepsSnapshot = await instanceDoc.reference
            .collection('scheduledSteps')
            .where('scheduledFor', isLessThanOrEqualTo: Timestamp.fromDate(now))
            .orderBy('scheduledFor')
            .limit(1)
            .get();

        if (scheduledStepsSnapshot.docs.isEmpty) continue;

        final scheduledStep = scheduledStepsSnapshot.docs.first;
        final stepData = scheduledStep.data();

        // Get sequence
        final sequenceDoc = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('emailSequences')
            .doc(instance.sequenceId)
            .get();

        if (!sequenceDoc.exists) continue;

        final sequence = EmailSequence.fromMap(instance.sequenceId, sequenceDoc.data()!);

        // Get tenant
        final tenant = await TenantService.getTenantById(
          facilityId,
          instance.tenantId,
        );

        if (tenant == null) continue;
        
        // Get facility for language preferences
        final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
        final facility = facilityDoc.exists ? FacilityModel.fromFirestore(facilityDoc) : null;
        
        // Extract language code from tenant's preferredLocale or facility's defaultLocale
        String? languageCode = TemplateIntegrationService.extractLanguageCode(
          tenant.preferredLocale ?? facility?.defaultLocale,
        );
        
        // Try to use language-aware template if step has a template category
        String? html = stepData['htmlBody'] as String?;
        String? text = stepData['textBody'] as String?;
        String? subject = stepData['subject'] as String?;
        
        // If step has a template category, try to get language-aware template
        final templateCategory = stepData['templateCategory'] as String?;
        if (templateCategory != null) {
          // Prepare template variables
          final vars = <String, String>{
            'tenantName': tenant.name,
            'facilityName': facility?.name ?? 'Property Management',
            if (html != null) 'message': html.replaceAll(RegExp(r'<[^>]*>'), ''), // Extract text from HTML
          };
          
          // Try to get language-aware template
          final templateResult = await TemplateIntegrationService.getEmailTemplate(
            category: templateCategory,
            facilityId: facilityId,
            variables: vars,
            language: languageCode,
          );
          
          if (templateResult != null) {
            html = templateResult.htmlBody;
            text = templateResult.textBody;
            subject = templateResult.subject;
            
            if (kDebugMode) {
              print('✅ [EmailSequence] Using language-aware template (language: ${languageCode ?? "default"})');
            }
          }
        }

        // Send email
        try {
          final result = await EmailCloudService.sendEmail(
            facilityId: facilityId,
            to: tenant.email,
            subject: subject ?? stepData['subject'] as String,
            html: html ?? stepData['htmlBody'] as String,
            text: text ?? stepData['textBody'] as String?,
          );

          final messageId = result.messageId;

          // Record delivery
          await instanceDoc.reference
              .collection('deliveries')
              .add({
            'stepOrder': stepData['stepOrder'],
            'subject': stepData['subject'],
            'sentAt': FieldValue.serverTimestamp(),
            'success': true,
            'messageId': messageId,
          });

          // Delete scheduled step
          await scheduledStep.reference.delete();

          // Update instance
          final nextStepIndex = instance.currentStep + 1;
          await instanceDoc.reference.update({
            'currentStep': nextStepIndex,
          });

          // Schedule next step
          await _scheduleNextStep(
            instance.id,
            facilityId,
            instance.tenantId,
            sequence,
            nextStepIndex,
          );

          if (kDebugMode) {
            print('✅ [EmailSequence] Sent step ${stepData['stepOrder']} for instance ${instance.id}');
          }
        } catch (e) {
          if (kDebugMode) {
            print('❌ [EmailSequence] Error sending step: $e');
          }

          // Record failed delivery
          await instanceDoc.reference
              .collection('deliveries')
              .add({
            'stepOrder': stepData['stepOrder'],
            'subject': stepData['subject'],
            'sentAt': FieldValue.serverTimestamp(),
            'success': false,
            'errorMessage': e.toString(),
            'messageId': null,
          });
        }
      }

      if (kDebugMode) {
        print('✅ [EmailSequence] Processed pending steps for facility: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error processing pending steps: $e');
      }
    }
  }

  /// Stop/cancel an email sequence instance
  static Future<void> stopSequenceInstance({
    required String facilityId,
    required String instanceId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequenceInstances')
          .doc(instanceId)
          .update({
        'status': SequenceStatus.cancelled.name,
        'completedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [EmailSequence] Stopped sequence instance: $instanceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error stopping sequence instance: $e');
      }
      rethrow;
    }
  }

  /// Get sequence instances for a tenant
  static Future<List<EmailSequenceInstance>> getTenantSequenceInstances({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequenceInstances')
          .where('tenantId', isEqualTo: tenantId)
          .orderBy('startedAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => EmailSequenceInstance.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error getting tenant instances: $e');
      }
      return [];
    }
  }

  /// Delete an email sequence
  static Future<void> deleteEmailSequence({
    required String facilityId,
    required String sequenceId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailSequences')
          .doc(sequenceId)
          .update({'isActive': false});

      if (kDebugMode) {
        print('✅ [EmailSequence] Deleted email sequence: $sequenceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailSequence] Error deleting sequence: $e');
      }
      rethrow;
    }
  }
}
