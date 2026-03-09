import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/reminder_model.dart';
import 'package:sfcapp/models/reminder_schedule_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/billing_service.dart';
import 'package:sfcapp/services/email_cloud_service.dart';
import 'package:sfcapp/services/email_template_service.dart';
import 'package:sfcapp/services/reminders_digest_service.dart';
import 'package:sfcapp/services/sms_service.dart';
import 'package:sfcapp/services/template_integration_service.dart';
import 'package:sfcapp/services/audit_service.dart';

class ReminderService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  
  // Create a reminder
  static Future<ReminderModel> createReminder({
    required String tenantId,
    required String facilityId,
    String? contractId,
    String? paymentId,
    required ReminderType type,
    required List<ReminderChannel> channels,
    required String title,
    required String message,
    required DateTime scheduledFor,
    String? tenantEmail,
    String? tenantPhone,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');
      
      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .doc();
      
      final now = DateTime.now();
      
      final reminderData = {
        'tenantId': tenantId,
        'facilityId': facilityId,
        'contractId': contractId,
        'paymentId': paymentId,
        if (tenantEmail != null) 'tenantEmail': tenantEmail,
        if (tenantPhone != null) 'tenantPhone': tenantPhone,
        'type': type.name,
        'status': 'pending',
        'channels': channels.map((c) => c.name).toList(),
        'title': title,
        'message': message,
        'scheduledFor': Timestamp.fromDate(scheduledFor),
        'metadata': metadata,
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        'createdBy': user.uid,
        'isActive': true,
      };

      await ref.set(reminderData);

      final reminder = ReminderModel(
        id: ref.id,
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: contractId,
        paymentId: paymentId,
        tenantEmail: tenantEmail,
        tenantPhone: tenantPhone,
        type: type,
        status: ReminderStatus.pending,
        channels: channels,
        title: title,
        message: message,
        scheduledFor: scheduledFor,
        metadata: metadata,
        createdAt: now,
        updatedAt: now,
        createdBy: user.uid,
        isActive: true,
      );

      if (kDebugMode) {
        print('✅ Reminder created successfully: ${ref.id}');
      }

      return reminder;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating reminder: $e');
      }
      rethrow;
    }
  }

  // Get reminders for a facility (real-time stream)
  static Stream<List<ReminderModel>> getRemindersForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up reminders stream for facility: $facilityId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders');
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('createdAt', descending: true);
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final reminders = snapshot.docs.map((doc) {
          return ReminderModel.fromFirestore(doc);
        }).toList();

        // Sort in memory if we used fallback query
        reminders.sort((a, b) => b.createdAt.compareTo(a.createdAt));

        if (kDebugMode) {
          print('📡 Stream update: ${reminders.length} reminders for facility: $facilityId');
        }

        return reminders;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up reminders stream: $e');
      }
      rethrow;
    }
  }

  // Get reminders for a facility
  static Future<List<ReminderModel>> getRemindersForFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting reminders for facility: $facilityId');
      }

      // Try ordered query first, fall back to unordered if index is building
      QuerySnapshot snapshot;
      try {
        snapshot = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('reminders')
            .orderBy('scheduledFor', descending: true)
            .get();
      } catch (orderingError) {
        if (orderingError.toString().contains('failed-precondition') && orderingError.toString().contains('index')) {
          if (kDebugMode) {
            print('📋 INDEX BUILDING: Using fallback unordered query for reminders...');
          }
          // Fallback to unordered query
          snapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('reminders')
              .get();
        } else {
          rethrow;
        }
      }

      final reminders = snapshot.docs
          .map((doc) => ReminderModel.fromFirestore(doc))
          .toList();
          
      // Sort in memory (needed for fallback queries)
      reminders.sort((a, b) => b.scheduledFor.compareTo(a.scheduledFor));

      if (kDebugMode) {
        print('✅ Successfully retrieved ${reminders.length} reminders');
      }

      return reminders;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting reminders: $e');
      }
      return [];
    }
  }

  // Get reminders for a tenant
  static Future<List<ReminderModel>> getRemindersForTenant(String facilityId, String tenantId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting reminders for tenant: $tenantId');
      }

      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .where('tenantId', isEqualTo: tenantId)
          .where('isActive', isEqualTo: true)
          .orderBy('scheduledFor', descending: true)
          .get();

      final reminders = querySnapshot.docs
          .map((doc) => ReminderModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Successfully retrieved ${reminders.length} reminders for tenant');
      }

      return reminders;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting tenant reminders: $e');
      }
      return [];
    }
  }

  // Update reminder
  static Future<void> updateReminder({
    required String facilityId,
    required String reminderId,
    ReminderStatus? status,
    String? title,
    String? message,
    DateTime? scheduledFor,
    List<ReminderChannel>? channels,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Updating reminder: $reminderId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': user.uid,
      };

      if (status != null) updateData['status'] = status.name;
      if (title != null) updateData['title'] = title;
      if (message != null) updateData['message'] = message;
      if (scheduledFor != null) updateData['scheduledFor'] = Timestamp.fromDate(scheduledFor);
      if (channels != null) updateData['channels'] = channels.map((c) => c.name).toList();
      if (metadata != null) updateData['metadata'] = metadata;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .doc(reminderId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Reminder updated successfully: $reminderId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating reminder: $e');
      }
      rethrow;
    }
  }

  // Mark reminder as sent
  static Future<void> markReminderAsSent({
    required String facilityId,
    required String reminderId,
    String? sentVia,
    String? sentTo,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Marking reminder as sent: $reminderId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .doc(reminderId)
          .update({
        'status': 'sent',
        'sentAt': Timestamp.fromDate(DateTime.now()),
        'sentVia': sentVia,
        'sentTo': sentTo,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': user.uid,
      });

      if (kDebugMode) {
        print('✅ Reminder marked as sent successfully: $reminderId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error marking reminder as sent: $e');
      }
      rethrow;
    }
  }

  // Archive reminder (soft delete)
  static Future<void> archiveReminder(String facilityId, String reminderId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Archiving reminder: $reminderId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .doc(reminderId)
          .update({
        'isActive': false,
        'archivedAt': Timestamp.fromDate(DateTime.now()),
        'archivedByUid': user.uid,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      if (kDebugMode) {
        print('✅ Reminder archived successfully: $reminderId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error archiving reminder: $e');
      }
      rethrow;
    }
  }

  // Delete reminder (hard delete)
  static Future<void> deleteReminder(String facilityId, String reminderId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Deleting reminder: $reminderId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .doc(reminderId)
          .delete();

      if (kDebugMode) {
        print('✅ Reminder deleted successfully: $reminderId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting reminder: $e');
      }
      rethrow;
    }
  }

  // Get pending reminders (for processing)
  static Future<List<ReminderModel>> getPendingReminders(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting pending reminders for facility: $facilityId');
      }

      final now = DateTime.now();
      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .where('isActive', isEqualTo: true)
          .where('status', isEqualTo: 'pending')
          .where('scheduledFor', isLessThanOrEqualTo: Timestamp.fromDate(now))
          .orderBy('scheduledFor')
          .get();

      final reminders = querySnapshot.docs
          .map((doc) => ReminderModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Found ${reminders.length} pending reminders');
      }

      return reminders;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting pending reminders: $e');
      }
      return [];
    }
  }

  // Reminder schedules -------------------------------------------------------
  static Stream<List<ReminderScheduleModel>> getReminderSchedulesStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminderSchedules');

      try {
        query = query.orderBy('name');
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available for reminder schedules: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final schedules = snapshot.docs
            .map((doc) => ReminderScheduleModel.fromFirestore(doc))
            .toList();
        schedules.sort((a, b) => a.name.compareTo(b.name));
        return schedules;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error streaming reminder schedules: $e');
      }
      rethrow;
    }
  }

  static Future<ReminderScheduleModel> createReminderSchedule({
    required String facilityId,
    required String name,
    required ReminderType type,
    required List<ReminderChannel> channels,
    required ReminderSendMode sendMode,
    required int offsetDays,
    required String sendTime,
    required bool autoSend,
    required bool isActive,
    required String titleTemplate,
    required String messageTemplate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminderSchedules')
          .doc();

      final now = DateTime.now();
      final data = {
        'facilityId': facilityId,
        'name': name,
        'type': type.name,
        'channels': channels.map((c) => c.name).toList(),
        'sendMode': sendMode.name,
        'offsetDays': offsetDays,
        'sendTime': sendTime,
        'autoSend': autoSend,
        'isActive': isActive,
        'titleTemplate': titleTemplate,
        'messageTemplate': messageTemplate,
        'lastRunDate': null,
        'lastRunAt': null,
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        'createdBy': user.uid,
      };

      await ref.set(data);

      if (kDebugMode) {
        print('✅ Reminder schedule created: ${ref.id}');
      }

      return ReminderScheduleModel(
        id: ref.id,
        facilityId: facilityId,
        name: name,
        type: type,
        channels: channels,
        sendMode: sendMode,
        offsetDays: offsetDays,
        sendTime: sendTime,
        autoSend: autoSend,
        isActive: isActive,
        titleTemplate: titleTemplate,
        messageTemplate: messageTemplate,
        lastRunDate: null,
        lastRunAt: null,
        createdAt: now,
        updatedAt: now,
        createdBy: user.uid,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating reminder schedule: $e');
      }
      rethrow;
    }
  }

  static Future<void> updateReminderSchedule({
    required String facilityId,
    required String scheduleId,
    String? name,
    ReminderType? type,
    List<ReminderChannel>? channels,
    ReminderSendMode? sendMode,
    int? offsetDays,
    String? sendTime,
    bool? autoSend,
    bool? isActive,
    String? titleTemplate,
    String? messageTemplate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final updates = <String, dynamic>{
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': user.uid,
      };

      if (name != null) updates['name'] = name;
      if (type != null) updates['type'] = type.name;
      if (channels != null) updates['channels'] = channels.map((c) => c.name).toList();
      if (sendMode != null) updates['sendMode'] = sendMode.name;
      if (offsetDays != null) updates['offsetDays'] = offsetDays;
      if (sendTime != null) updates['sendTime'] = sendTime;
      if (autoSend != null) updates['autoSend'] = autoSend;
      if (isActive != null) updates['isActive'] = isActive;
      if (titleTemplate != null) updates['titleTemplate'] = titleTemplate;
      if (messageTemplate != null) updates['messageTemplate'] = messageTemplate;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminderSchedules')
          .doc(scheduleId)
          .update(updates);

      if (kDebugMode) {
        print('✅ Reminder schedule updated: $scheduleId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating reminder schedule: $e');
      }
      rethrow;
    }
  }

  static Future<void> deleteReminderSchedule({
    required String facilityId,
    required String scheduleId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminderSchedules')
          .doc(scheduleId)
          .delete();

      if (kDebugMode) {
        print('🗑️ Reminder schedule deleted: $scheduleId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting reminder schedule: $e');
      }
      rethrow;
    }
  }

  static Future<void> toggleReminderSchedule({
    required String facilityId,
    required String scheduleId,
    required bool isActive,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminderSchedules')
          .doc(scheduleId)
          .update({
        'isActive': isActive,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': user.uid,
      });

      if (kDebugMode) {
        print('🔄 Reminder schedule ${isActive ? 'enabled' : 'disabled'}: $scheduleId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error toggling reminder schedule: $e');
      }
      rethrow;
    }
  }

  static Future<void> updateReminderScheduleRunDate({
    required String facilityId,
    required String scheduleId,
    required DateTime runAt,
  }) async {
    final runDate = '${runAt.year.toString().padLeft(4, '0')}-'
        '${runAt.month.toString().padLeft(2, '0')}-'
        '${runAt.day.toString().padLeft(2, '0')}';

    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminderSchedules')
          .doc(scheduleId)
          .update({
        'lastRunDate': runDate,
        'lastRunAt': Timestamp.fromDate(runAt),
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating schedule run metadata: $e');
      }
    }
  }

  static Future<List<ReminderScheduleModel>> getActiveReminderSchedules(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminderSchedules')
          .where('isActive', isEqualTo: true)
          .get();

      final schedules = snapshot.docs
          .map((doc) => ReminderScheduleModel.fromFirestore(doc))
          .toList();
      schedules.sort((a, b) => a.name.compareTo(b.name));
      return schedules;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading active reminder schedules: $e');
      }
      return [];
    }
  }

  /// Send reminder with new email system
  static Future<bool> sendReminder({
    required String facilityId,
    required String reminderId,
    required String tenantEmail,
    required String tenantPhone,
    required String message,
    required List<ReminderChannel> channels,
    ReminderSendMode mode = ReminderSendMode.immediate,
    String? digestKey,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Sending reminder: $reminderId via ${channels.map((c) => c.name).join(', ')} (mode: ${mode.name})');
      }

      // Check billing limits before sending
      final canSend = await BillingService.canSendEmails(facilityId);
      if (!canSend) {
        final warning = await BillingService.getUsageWarning(facilityId);
        if (kDebugMode) {
          print('⚠️ [ReminderService] Email limit exceeded: $warning');
        }
        // Still allow sending but log the warning
      }

      bool success = false;
      final sentChannels = <String>[];

      // Process each channel
      for (final channel in channels) {
        switch (channel) {
          case ReminderChannel.email:
            if (mode == ReminderSendMode.digest && digestKey != null) {
              // Queue for digest
              await _queueEmailForDigest(
                facilityId: facilityId,
                tenantEmail: tenantEmail,
                message: message,
                digestKey: digestKey,
              );
              sentChannels.add('email (digest)');
              success = true;
            } else {
              // Send immediately
              final emailSuccess = await _sendEmailReminder(
                facilityId: facilityId,
                tenantEmail: tenantEmail,
                message: message,
                reminderId: reminderId,
                templateId: 'due_default',
              );
              if (emailSuccess) {
                sentChannels.add('email');
                success = true;
              }
            }
            break;
            
          case ReminderChannel.sms:
            if (tenantPhone.isNotEmpty) {
              try {
                // Get tenant and facility for language-aware SMS template
                final tenantSnapshot = await _firestore
                    .collection('facilities')
                    .doc(facilityId)
                    .collection('tenants')
                    .where('phone', isEqualTo: tenantPhone)
                    .limit(1)
                    .get();
                
                String? smsMessage = message;
                String? languageCode;
                
                if (tenantSnapshot.docs.isNotEmpty) {
                  final tenant = TenantModel.fromFirestore(tenantSnapshot.docs.first);
                  final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
                  
                  if (facilityDoc.exists) {
                    final facility = FacilityModel.fromFirestore(facilityDoc);
                    
                    // Extract language code
                    languageCode = TemplateIntegrationService.extractLanguageCode(
                      tenant.preferredLocale ?? facility.defaultLocale,
                    );
                    
                    // Try to get language-aware SMS template
                    final templateResult = await TemplateIntegrationService.getSMSTemplate(
                      category: 'reminder',
                      facilityId: facilityId,
                      variables: {
                        'tenantName': tenant.name,
                        'facilityName': facility.name,
                        'message': message,
                        'amount': tenant.monthlyRate.toStringAsFixed(2),
                        'unitNumber': tenant.unitNumber,
                      },
                      language: languageCode,
                    );
                    
                    if (templateResult != null) {
                      smsMessage = templateResult.message;
                      if (kDebugMode) {
                        print('✅ [ReminderService] Using language-aware SMS template (language: ${languageCode ?? "default"})');
                      }
                    }
                  }
                }
                
                final smsResult = await SMSService.sendSMS(
                  to: tenantPhone,
                  message: smsMessage,
                  facilityId: facilityId,
                );
                if (smsResult.success) {
                  sentChannels.add('sms');
                  success = true;
                } else {
                  if (kDebugMode) {
                    print('❌ Failed to send SMS: ${smsResult.error}');
                  }
                }
              } catch (e) {
                if (kDebugMode) {
                  print('❌ Error sending SMS: $e');
                }
              }
            } else {
              if (kDebugMode) {
                print('⚠️ Cannot send SMS: tenant phone number not available');
              }
            }
            break;
            
          case ReminderChannel.push:
            // Push notifications still use mock implementation
            if (kDebugMode) {
              print('🔔 Mock push notification sent');
              print('🔔 Message: $message');
            }
            sentChannels.add('push');
            success = true;
            break;
            
          case ReminderChannel.inApp:
            // In-app notifications still use mock implementation
            if (kDebugMode) {
              print('📱 Mock in-app notification sent');
              print('📱 Message: $message');
            }
            sentChannels.add('in-app');
            success = true;
            break;
        }
      }

      // Mark as sent if any channel succeeded
      if (success) {
        await markReminderAsSent(
          facilityId: facilityId,
          reminderId: reminderId,
          sentVia: sentChannels.join(', '),
          sentTo: tenantEmail,
        );

        // Billing count is now handled by Cloud Functions

        if (kDebugMode) {
          print('✅ Reminder sent successfully: $reminderId via ${sentChannels.join(', ')}');
        }
      }

      return success;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error sending reminder: $e');
      }
      return false;
    }
  }

  /// Send email reminder immediately
  static Future<bool> _sendEmailReminder({
    required String facilityId,
    required String tenantEmail,
    required String message,
    required String reminderId,
    String? templateId,
    Map<String, dynamic>? templateVars,
  }) async {
    try {
      // Get facility and tenant info for template variables
      final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
      final tenantSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('email', isEqualTo: tenantEmail)
          .limit(1)
          .get();

      if (facilityDoc.exists && tenantSnapshot.docs.isNotEmpty) {
        // Get tenant and facility models to access locale preferences
        final tenant = TenantModel.fromFirestore(tenantSnapshot.docs.first);
        final facility = FacilityModel.fromFirestore(facilityDoc);
        
        // Extract language code from tenant's preferredLocale or facility's defaultLocale
        String? languageCode = TemplateIntegrationService.extractLanguageCode(
          tenant.preferredLocale ?? facility.defaultLocale,
        );
        
        // Prepare template variables
        final vars = <String, String>{
          'tenantName': tenant.name,
          'facilityName': facility.name,
          'message': message,
          'amount': tenant.monthlyRate.toStringAsFixed(2),
          'unitNumber': tenant.unitNumber,
          'dueDate': DateTime.now().add(const Duration(days: 30)).toString().split(' ')[0],
          if (templateVars != null) ...templateVars.map((key, value) => MapEntry(key, value.toString())),
        };

        // Try to use TemplateIntegrationService for language-aware templates
        String? html;
        String? text;
        String? subject;
        
        // Determine template category based on reminder type or use 'reminder' as default
        final templateCategory = 'reminder'; // Could be enhanced to use reminder.type
        
        // Try to get language-aware template
        final templateResult = await TemplateIntegrationService.getEmailTemplate(
          category: templateCategory,
          facilityId: facilityId,
          variables: vars,
          language: languageCode, // Pass language code for language-aware selection
        );
        
        if (templateResult != null) {
          // Use language-aware template
          html = templateResult.htmlBody;
          text = templateResult.textBody;
          subject = templateResult.subject;
          
          if (kDebugMode) {
            print('✅ [ReminderService] Using language-aware template (language: ${languageCode ?? "default"})');
          }
        } else {
          // Fallback to old template system if language-aware template not found
          if (templateId != null) {
            final oldTemplateResult = await EmailTemplateService.renderTemplate(
              templateId: templateId,
              variables: vars.map((key, value) => MapEntry(key, value)),
            );
            if (oldTemplateResult.success) {
              html = oldTemplateResult.html;
              text = oldTemplateResult.text;
            }
          }
          
          // Final fallback to simple HTML
          if (html == null) {
            html = EmailTemplateService.generateSimpleHtml(
              title: 'Payment Due Reminder',
              message: message,
              facilityName: facility.name,
              tenantName: tenant.name,
              unitNumber: tenant.unitNumber,
              amount: tenant.monthlyRate.toString(),
              dueDate: DateTime.now().add(const Duration(days: 30)).toString().split(' ')[0],
            );
            text = message;
          }
          
          subject ??= 'Reminder from ${facility.name}';
        }

        // Send via EmailCloudService (Cloud Functions + SES)
        final result = await EmailCloudService.sendEmail(
          to: tenantEmail,
          subject: subject ?? 'Reminder from ${facility.name}',
          html: html ?? _generateHtmlEmail(message),
          text: text ?? message,
          facilityId: facilityId,
          templateId: templateId,
          variables: vars.map((key, value) => MapEntry(key, value)),
        );

        if (result.success) {
          if (kDebugMode) {
            print('📧 [ReminderService] Email sent successfully to: $tenantEmail');
            print('📧 [ReminderService] Message ID: ${result.messageId}');
          }
          return true;
        } else {
          if (kDebugMode) {
            print('❌ [ReminderService] Email failed: ${result.error}');
          }
          return false;
        }
      } else {
        // Fallback to simple email without template
        final result = await EmailCloudService.sendEmail(
          to: tenantEmail,
          subject: 'Reminder from Property Management',
          text: message,
          html: _generateHtmlEmail(message),
          facilityId: facilityId,
        );

        if (result.success) {
          if (kDebugMode) {
            print('📧 [ReminderService] Simple email sent successfully to: $tenantEmail');
          }
          return true;
        } else {
          if (kDebugMode) {
            print('❌ [ReminderService] Simple email failed: ${result.error}');
          }
          return false;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReminderService] Error sending email: $e');
      }
      return false;
    }
  }

  /// Queue email for digest sending
  static Future<void> _queueEmailForDigest({
    required String facilityId,
    required String tenantEmail,
    required String message,
    required String digestKey,
  }) async {
    try {
      // Get tenant ID from email (this is a simplified approach)
      // In a real implementation, you'd want to store tenant ID with the reminder
      final tenantSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('email', isEqualTo: tenantEmail)
          .limit(1)
          .get();

      if (tenantSnapshot.docs.isEmpty) {
        throw Exception('Tenant not found for email: $tenantEmail');
      }

      final tenantId = tenantSnapshot.docs.first.id;

      await RemindersDigestService.queueReminderForDigest(
        facilityId: facilityId,
        tenantId: tenantId,
        templateId: 'reminder',
        templateVars: {
          'title': 'Property Reminder',
          'message': message,
          'tenantEmail': tenantEmail,
        },
        digestKey: digestKey,
      );

      if (kDebugMode) {
        print('📧 [ReminderService] Email queued for digest: $digestKey');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReminderService] Error queuing email for digest: $e');
      }
      rethrow;
    }
  }

  /// Generate HTML email content
  static String _generateHtmlEmail(String message) {
    return '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { background-color: #f4f4f4; padding: 20px; text-align: center; }
        .content { padding: 20px; }
        .footer { background-color: #f4f4f4; padding: 20px; text-align: center; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>Property Management Reminder</h2>
        </div>
        <div class="content">
            <p>$message</p>
            <p>Please contact us if you have any questions.</p>
        </div>
        <div class="footer">
            <p>Best regards,<br>Property Management Team</p>
        </div>
    </div>
</body>
</html>
    ''';
  }


  // Get reminder statistics for a facility
  static Future<Map<String, dynamic>> getReminderStatistics(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting reminder statistics for facility: $facilityId');
      }

      final reminders = await getRemindersForFacility(facilityId);
      
      final totalReminders = reminders.length;
      final sentReminders = reminders.where((r) => r.status == ReminderStatus.sent).length;
      final pendingReminders = reminders.where((r) => r.status == ReminderStatus.pending).length;
      final failedReminders = reminders.where((r) => r.status == ReminderStatus.failed).length;

      final statistics = {
        'totalReminders': totalReminders,
        'sentReminders': sentReminders,
        'pendingReminders': pendingReminders,
        'failedReminders': failedReminders,
        'successRate': totalReminders > 0 ? (sentReminders / totalReminders) * 100 : 0.0,
      };

      if (kDebugMode) {
        print('✅ Reminder statistics calculated: $statistics');
      }

      return statistics;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting reminder statistics: $e');
      }
      return {};
    }
  }
}