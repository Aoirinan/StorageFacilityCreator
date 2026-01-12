import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/contract_model.dart';
import '../models/payment_model.dart';
import '../models/reminder_model.dart';
import '../models/reminder_schedule_model.dart';
import '../models/tenant_model.dart';
import '../services/contract_service.dart';
import '../services/facility_service.dart';
import '../services/payment_service.dart';
import '../services/reminder_service.dart';
import '../services/reminders_digest_service.dart';
import '../services/tenant_service.dart';

class ReminderAutomationResult {
  final int schedulesProcessed;
  final int remindersCreated;
  final int remindersSent;
  final int digestQueued;

  const ReminderAutomationResult({
    required this.schedulesProcessed,
    required this.remindersCreated,
    required this.remindersSent,
    required this.digestQueued,
  });
}

class ReminderAutomationService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static Future<ReminderAutomationResult> runFacilitySchedules(
    String facilityId, {
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now();
    final schedules = await ReminderService.getActiveReminderSchedules(facilityId);
    if (schedules.isEmpty) {
      if (kDebugMode) {
        print('📅 [ReminderAutomation] No active schedules found for facility: $facilityId');
      }
      return const ReminderAutomationResult(
        schedulesProcessed: 0,
        remindersCreated: 0,
        remindersSent: 0,
        digestQueued: 0,
      );
    }

    final facility = await FacilityService.getFacility(facilityId);
    if (facility == null) {
      if (kDebugMode) {
        print('❌ [ReminderAutomation] Facility not accessible: $facilityId');
      }
      return const ReminderAutomationResult(
        schedulesProcessed: 0,
        remindersCreated: 0,
        remindersSent: 0,
        digestQueued: 0,
      );
    }

    final tenantCache = <String, TenantModel?>{};
    final paymentCache = <String, PaymentModel>{};
    final contractCache = <String, ContractModel>{};

    int processed = 0;
    int created = 0;
    int sent = 0;
    int digestQueued = 0;

    for (final schedule in schedules) {
      if (!schedule.shouldRun(current)) {
        continue;
      }

      if (kDebugMode) {
        print('⏱️ [ReminderAutomation] Running schedule ${schedule.name} (${schedule.id})');
      }

      final targets = await _generateReminderTargets(
        schedule: schedule,
        facilityId: facilityId,
        facilityName: facility.name,
        tenantCache: tenantCache,
        paymentCache: paymentCache,
        contractCache: contractCache,
        now: current,
      );

      if (targets.isEmpty) {
        await ReminderService.updateReminderScheduleRunDate(
          facilityId: facilityId,
          scheduleId: schedule.id,
          runAt: current,
        );
        processed++;
        continue;
      }

      for (final target in targets) {
        final reminderId = await _createOrSendReminder(
          schedule: schedule,
          facilityId: facilityId,
          facilityName: facility.name,
          tenant: target.tenant,
          payment: target.payment,
          contract: target.contract,
          now: current,
        );

        if (reminderId != null) {
          created++;
          if (schedule.autoSend) {
            if (schedule.sendMode == ReminderSendMode.digest) {
              digestQueued++;
            } else {
              sent++;
            }
          }
        }
      }

      await ReminderService.updateReminderScheduleRunDate(
        facilityId: facilityId,
        scheduleId: schedule.id,
        runAt: current,
      );

      processed++;
    }

    return ReminderAutomationResult(
      schedulesProcessed: processed,
      remindersCreated: created,
      remindersSent: sent,
      digestQueued: digestQueued,
    );
  }

  static Future<List<_ReminderTarget>> _generateReminderTargets({
    required ReminderScheduleModel schedule,
    required String facilityId,
    required String facilityName,
    required Map<String, TenantModel?> tenantCache,
    required Map<String, PaymentModel> paymentCache,
    required Map<String, ContractModel> contractCache,
    required DateTime now,
  }) async {
    switch (schedule.type) {
      case ReminderType.rentDue:
        return _generateRentDueTargets(
          schedule: schedule,
          facilityId: facilityId,
          facilityName: facilityName,
          tenantCache: tenantCache,
          paymentCache: paymentCache,
          now: now,
        );
      case ReminderType.rentOverdue:
        return _generateRentOverdueTargets(
          schedule: schedule,
          facilityId: facilityId,
          facilityName: facilityName,
          tenantCache: tenantCache,
          paymentCache: paymentCache,
          now: now,
        );
      case ReminderType.contractExpiring:
        return _generateContractExpiringTargets(
          schedule: schedule,
          facilityId: facilityId,
          tenantCache: tenantCache,
          contractCache: contractCache,
          now: now,
        );
      case ReminderType.contractExpired:
      case ReminderType.paymentFailed:
      case ReminderType.maintenanceDue:
      case ReminderType.inspectionDue:
      case ReminderType.custom:
        if (kDebugMode) {
          print('ℹ️ [ReminderAutomation] Schedule type ${schedule.type.name} not automated yet');
        }
        return const [];
    }
  }

  static Future<List<_ReminderTarget>> _generateRentDueTargets({
    required ReminderScheduleModel schedule,
    required String facilityId,
    required String facilityName,
    required Map<String, TenantModel?> tenantCache,
    required Map<String, PaymentModel> paymentCache,
    required DateTime now,
  }) async {
    final pendingPayments = await _getPendingPayments(facilityId);
    if (pendingPayments.isEmpty) {
      return const [];
    }

    final targets = <_ReminderTarget>[];
    final targetDate = DateTime(now.year, now.month, now.day)
        .add(Duration(days: schedule.offsetDays));
    final start = targetDate;
    final end = targetDate.add(const Duration(days: 1));

    for (final payment in pendingPayments) {
      final dueDate = payment.dueDate;
      if (dueDate.isBefore(start) || dueDate.isAfter(end)) {
        continue;
      }

      final tenant = await _loadTenant(
        facilityId,
        payment.tenantId,
        tenantCache,
      );
      if (tenant == null) continue;
      if (tenant.email.isEmpty && tenant.phone.isEmpty) continue;

      final alreadyExists = await _hasExistingReminder(
        facilityId: facilityId,
        scheduleId: schedule.id,
        paymentId: payment.id,
      );
      if (alreadyExists) continue;

      targets.add(
        _ReminderTarget(
          tenant: tenant,
          payment: payment,
          contract: null,
        ),
      );
    }

    return targets;
  }

  static Future<List<_ReminderTarget>> _generateRentOverdueTargets({
    required ReminderScheduleModel schedule,
    required String facilityId,
    required String facilityName,
    required Map<String, TenantModel?> tenantCache,
    required Map<String, PaymentModel> paymentCache,
    required DateTime now,
  }) async {
    final pendingPayments = await _getPendingPayments(facilityId);
    if (pendingPayments.isEmpty) {
      return const [];
    }

    final targets = <_ReminderTarget>[];
    for (final payment in pendingPayments) {
      if (!payment.isOverdue) continue;
      final daysOverdue = max(0, now.difference(payment.dueDate).inDays);
      if (daysOverdue < schedule.offsetDays) continue;

      final tenant = await _loadTenant(
        facilityId,
        payment.tenantId,
        tenantCache,
      );
      if (tenant == null) continue;
      if (tenant.email.isEmpty && tenant.phone.isEmpty) continue;

      final alreadyExists = await _hasExistingReminder(
        facilityId: facilityId,
        scheduleId: schedule.id,
        paymentId: payment.id,
      );
      if (alreadyExists) continue;

      targets.add(
        _ReminderTarget(
          tenant: tenant,
          payment: payment,
          contract: null,
        ),
      );
    }

    return targets;
  }

  static Future<List<_ReminderTarget>> _generateContractExpiringTargets({
    required ReminderScheduleModel schedule,
    required String facilityId,
    required Map<String, TenantModel?> tenantCache,
    required Map<String, ContractModel> contractCache,
    required DateTime now,
  }) async {
    final contracts = await _getActiveContracts(facilityId);
    if (contracts.isEmpty) {
      return const [];
    }

    final targets = <_ReminderTarget>[];
    final targetDate = DateTime(now.year, now.month, now.day)
        .add(Duration(days: schedule.offsetDays));
    final start = targetDate;
    final end = targetDate.add(const Duration(days: 1));

    for (final contract in contracts) {
      final expiresAt = contract.expiresAt;
      if (expiresAt == null) continue;
      if (expiresAt.isBefore(start) || expiresAt.isAfter(end)) {
        continue;
      }

      final tenant = await _loadTenant(
        facilityId,
        contract.tenantId,
        tenantCache,
      );

      if (tenant == null) continue;
      if (tenant.email.isEmpty && tenant.phone.isEmpty) continue;

      final alreadyExists = await _hasExistingReminder(
        facilityId: facilityId,
        scheduleId: schedule.id,
        contractId: contract.id,
      );
      if (alreadyExists) continue;

      targets.add(
        _ReminderTarget(
          tenant: tenant,
          payment: null,
          contract: contract,
        ),
      );
    }

    return targets;
  }

  static Future<String?> _createOrSendReminder({
    required ReminderScheduleModel schedule,
    required String facilityId,
    required String facilityName,
    required TenantModel tenant,
    PaymentModel? payment,
    ContractModel? contract,
    required DateTime now,
  }) async {
    final replacements = <String, String>{
      'tenantName': tenant.name,
      'facilityName': facilityName,
      'unitNumber': tenant.unitNumber,
      'scheduleName': schedule.name,
    };

    if (payment != null) {
      replacements.addAll({
        'amount': payment.formattedAmount,
        'dueDate': _formatDate(payment.dueDate),
        'daysOverdue':
            payment.isOverdue ? now.difference(payment.dueDate).inDays.toString() : '0',
        'daysUntilDue':
            (!payment.isOverdue ? max(0, payment.dueDate.difference(now).inDays).toString() : '0'),
      });
    }

    if (contract != null) {
      replacements.addAll({
        'contractTitle': contract.title,
        'expiryDate': contract.expiresAt != null
            ? _formatDate(contract.expiresAt!)
            : '',
      });
    }

    final title = _renderTemplate(schedule.titleTemplate, replacements);
    final message = _renderTemplate(schedule.messageTemplate, replacements);

    final reminder = await ReminderService.createReminder(
      facilityId: facilityId,
      tenantId: tenant.id,
      contractId: contract?.id,
      paymentId: payment?.id,
      type: schedule.type,
      channels: schedule.channels,
      title: title,
      message: message,
      scheduledFor: _composeScheduledDate(schedule.sendTime, now),
      tenantEmail: tenant.email,
      tenantPhone: tenant.phone,
      metadata: {
        'scheduleId': schedule.id,
        'generatedAt': now.toIso8601String(),
        'offsetDays': schedule.offsetDays,
        if (payment != null) 'targetDueDate': payment.dueDate.toIso8601String(),
        if (contract != null && contract.expiresAt != null)
          'targetExpiryDate': contract.expiresAt!.toIso8601String(),
      },
    );

    if (!schedule.autoSend) {
      return reminder.id;
    }

    if (schedule.sendMode == ReminderSendMode.digest) {
      final digestKey = _digestKeyFor(schedule.type);
      await _queueDigestReminder(
        facilityId: facilityId,
        tenantId: tenant.id,
        title: title,
        message: message,
        replacements: replacements,
        digestKey: digestKey,
      );
      return reminder.id;
    }

    final success = await ReminderService.sendReminder(
      facilityId: facilityId,
      reminderId: reminder.id,
      tenantEmail: tenant.email,
      tenantPhone: tenant.phone,
      message: message,
      channels: schedule.channels,
      mode: schedule.sendMode,
      digestKey: _digestKeyFor(schedule.type),
    );

    if (!success) {
      if (kDebugMode) {
        print('⚠️ [ReminderAutomation] sendReminder failed for reminder ${reminder.id}');
      }
    }

    return reminder.id;
  }

  static Future<List<PaymentModel>> _getPendingPayments(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('status', isEqualTo: 'pending')
          .get();

      return snapshot.docs
          .map((doc) => PaymentModel.fromFirestore(doc))
          .where((payment) => payment.isActive)
          .toList();
    } catch (error) {
      if (kDebugMode) {
        print('⚠️ [ReminderAutomation] Pending payments query failed: $error');
      }
      final payments = await PaymentService.getPaymentsForFacility(facilityId);
      return payments.where((payment) => payment.status == PaymentStatus.pending).toList();
    }
  }

  static Future<List<ContractModel>> _getActiveContracts(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .where('isActive', isEqualTo: true)
          .where('status', isNotEqualTo: 'cancelled')
          .get();

      return snapshot.docs
          .map((doc) => ContractModel.fromFirestore(doc))
          .where((contract) => contract.status != ContractStatus.cancelled)
          .toList();
    } catch (error) {
      if (kDebugMode) {
        print('⚠️ [ReminderAutomation] Active contracts query failed: $error');
      }
      final contracts = await ContractService.getContractsForFacility(facilityId);
      return contracts.where((contract) => contract.isActive).toList();
    }
  }

  static Future<TenantModel?> _loadTenant(
    String facilityId,
    String tenantId,
    Map<String, TenantModel?> cache,
  ) async {
    if (cache.containsKey(tenantId)) {
      return cache[tenantId];
    }

    final tenant = await TenantService.getTenantById(facilityId, tenantId);
    if (tenant != null) {
      cache[tenantId] = tenant;
    } else {
      cache[tenantId] = null;
    }
    return tenant;
  }

  static Future<bool> _hasExistingReminder({
    required String facilityId,
    required String scheduleId,
    String? paymentId,
    String? contractId,
  }) async {
    Query query = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('reminders')
        .where('metadata.scheduleId', isEqualTo: scheduleId)
        .where('isActive', isEqualTo: true);

    if (paymentId != null) {
      query = query.where('paymentId', isEqualTo: paymentId);
    }
    if (contractId != null) {
      query = query.where('contractId', isEqualTo: contractId);
    }

    try {
      final snapshot = await query.limit(1).get();
      return snapshot.docs.isNotEmpty;
    } catch (error) {
      if (kDebugMode) {
        print('⚠️ [ReminderAutomation] Existing reminder query failed: $error');
      }
      // Fallback: fetch reminders by schedule id without compound where
      final fallback = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .where('isActive', isEqualTo: true)
          .get();
      return fallback.docs.any((doc) {
        final data = doc.data();
        final metadata = data['metadata'] as Map<String, dynamic>?;
        if (metadata == null) return false;
        final matchesSchedule = metadata['scheduleId'] == scheduleId;
        final matchesPayment = paymentId == null || data['paymentId'] == paymentId;
        final matchesContract = contractId == null || data['contractId'] == contractId;
        return matchesSchedule && matchesPayment && matchesContract;
      });
    }
  }

  static Future<void> _queueDigestReminder({
    required String facilityId,
    required String tenantId,
    required String title,
    required String message,
    required Map<String, String> replacements,
    required String digestKey,
  }) async {
    await RemindersDigestService.queueReminderForDigest(
      facilityId: facilityId,
      tenantId: tenantId,
      templateId: 'due_default',
      templateVars: {
        'title': title,
        'message': message,
        ...replacements,
      },
      digestKey: digestKey,
    );
  }

  static String _digestKeyFor(ReminderType type) {
    switch (type) {
      case ReminderType.rentDue:
        return 'due';
      case ReminderType.rentOverdue:
        return 'overdue';
      case ReminderType.contractExpiring:
        return 'contract';
      default:
        return 'general';
    }
  }

  static DateTime _composeScheduledDate(String time, DateTime now) {
    final parts = time.split(':');
    final hour = parts.length > 0 ? int.tryParse(parts[0]) ?? now.hour : now.hour;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? now.minute : now.minute;
    return DateTime(now.year, now.month, now.day, hour.clamp(0, 23), minute.clamp(0, 59));
  }

  static String _formatDate(DateTime date) {
    return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year.toString()}';
  }

  static String _renderTemplate(String template, Map<String, String> replacements) {
    var output = template;
    replacements.forEach((key, value) {
      output = output.replaceAll('{{$key}}', value);
    });
    return output;
  }
}

class _ReminderTarget {
  final TenantModel tenant;
  final PaymentModel? payment;
  final ContractModel? contract;

  const _ReminderTarget({
    required this.tenant,
    required this.payment,
    required this.contract,
  });
}

