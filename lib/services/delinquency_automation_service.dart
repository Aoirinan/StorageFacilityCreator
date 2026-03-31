import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/delinquency_stage_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/email_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/gate_access_service.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/sms_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/audit_service.dart';

/// Service for automating delinquency workflows
class DelinquencyAutomationService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Process delinquency for all tenants in a facility
  /// This should be called by a scheduled Cloud Function daily
  static Future<DelinquencyProcessingResult> processDelinquency({
    required String facilityId,
    bool dryRun = false, // Preview mode - don't actually apply actions
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Delinquency] Processing delinquency for facility: $facilityId');
      }

      // Get facility to check delinquency rules
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) {
        throw Exception('Facility not found');
      }

      final rules = _getDelinquencyRules(facility);

      // Get all active tenants (with safety checks)
      final tenants = await TenantService.getTenantsForFacility(facilityId);
      final activeTenants = tenants.where((t) {
        // Must be active
        if (!t.isActive) return false;
        // Skip if moved out (check for moveOutDate in tenant data)
        // Note: TenantModel doesn't expose moveOutDate directly, but isActive should cover this
        return true;
      }).toList();

      int processedCount = 0;
      int lateFeeAppliedCount = 0;
      int noticeSentCount = 0;
      int lockoutCount = 0;
      int errors = 0;
      final errorMessages = <String>[];

      for (final tenant in activeTenants) {
        try {
          // Check if tenant is delinquent
          if (!tenant.isLate && tenant.daysLate == 0) {
            // Check if there's an active delinquency stage that should be resolved
            await _checkAndResolveDelinquency(tenant, facilityId);
            continue;
          }

          // Get current balance
          final balance = await LedgerService.getLedgerBalance(
            tenantId: tenant.id,
            facilityId: facilityId,
          );

          if (balance <= 0) {
            // Balance is paid, resolve delinquency
            await _checkAndResolveDelinquency(tenant, facilityId);
            continue;
          }

          // Get or create delinquency stage
          final stage = await _getOrCreateDelinquencyStage(
            tenant: tenant,
            facilityId: facilityId,
            balance: balance,
          );

          // Process based on current stage and rules
          final result = await _processDelinquencyStage(
            tenant: tenant,
            facilityId: facilityId,
            stage: stage,
            rules: rules,
            balance: balance,
            dryRun: dryRun,
          );

          processedCount++;
          if (result.lateFeeApplied) lateFeeAppliedCount++;
          if (result.noticeSent) noticeSentCount++;
          if (result.lockoutTriggered) lockoutCount++;
        } catch (e) {
          errors++;
          final errorMsg = 'Tenant ${tenant.name} (${tenant.id}): $e';
          errorMessages.add(errorMsg);
          if (kDebugMode) {
            print('❌ [Delinquency] Error processing tenant ${tenant.id}: $e');
          }
        }
      }

      if (kDebugMode) {
        print('✅ [Delinquency] Processed: $processedCount tenants, $lateFeeAppliedCount late fees, $noticeSentCount notices, $lockoutCount lockouts, $errors errors');
      }

      return DelinquencyProcessingResult(
        success: true,
        processedCount: processedCount,
        lateFeeAppliedCount: lateFeeAppliedCount,
        noticeSentCount: noticeSentCount,
        lockoutCount: lockoutCount,
        errorCount: errors,
        errors: errorMessages,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Delinquency] Error processing delinquency: $e');
      }
      return DelinquencyProcessingResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Get delinquency rules from facility settings
  static DelinquencyRules _getDelinquencyRules(FacilityModel facility) {
    final billingSettings = facility.billingSettings ?? {};
    
    return DelinquencyRules(
      gracePeriodDays: billingSettings['gracePeriodDays'] ?? 3,
      baseLateFee: (billingSettings['baseLateFee'] ?? 25.0).toDouble(),
      dailyLateFee: (billingSettings['dailyLateFee'] ?? 5.0).toDouble(),
      noticeDays: billingSettings['noticeDays'] ?? 7,
      finalNoticeDays: billingSettings['finalNoticeDays'] ?? 14,
      lienDays: billingSettings['lienDays'] ?? 30,
      lockoutDays: billingSettings['lockoutDays'] ?? 45,
      enableAutoLateFees: billingSettings['enableAutoLateFees'] ?? true,
      enableAutoNotices: billingSettings['enableAutoNotices'] ?? true,
      enableAutoLockout: billingSettings['enableAutoLockout'] ?? false,
    );
  }

  /// Get or create delinquency stage for tenant
  static Future<DelinquencyStageModel> _getOrCreateDelinquencyStage({
    required TenantModel tenant,
    required String facilityId,
    required double balance,
  }) async {
    // Check for existing stage
    final stageSnapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('delinquencyStages')
        .where('tenantId', isEqualTo: tenant.id)
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (stageSnapshot.docs.isNotEmpty) {
      final stage = DelinquencyStageModel.fromFirestore(stageSnapshot.docs.first);
      // Update balance and days overdue
      await stageSnapshot.docs.first.reference.update({
        'totalBalance': balance,
        'daysOverdue': tenant.daysLate,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return stage.copyWith(
        totalBalance: balance,
        daysOverdue: tenant.daysLate,
      );
    }

    // Create new stage
    final newStage = DelinquencyStageModel(
      id: '',
      facilityId: facilityId,
      tenantId: tenant.id,
      currentStage: _determineStage(tenant.daysLate),
      stageDate: DateTime.now(),
      totalBalance: balance,
      lateFees: 0.0,
      daysOverdue: tenant.daysLate,
      createdAt: DateTime.now(),
    );

    final docRef = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('delinquencyStages')
        .add(newStage.toFirestore());

    return newStage.copyWith(id: docRef.id);
  }

  /// Determine delinquency stage based on days overdue
  static DelinquencyStage _determineStage(int daysOverdue) {
    if (daysOverdue <= 0) return DelinquencyStage.current;
    if (daysOverdue <= 7) return DelinquencyStage.late;
    if (daysOverdue <= 30) return DelinquencyStage.overdue;
    return DelinquencyStage.noticeSent;
  }

  /// Process delinquency stage based on rules
  static Future<StageProcessingResult> _processDelinquencyStage({
    required TenantModel tenant,
    required String facilityId,
    required DelinquencyStageModel stage,
    required DelinquencyRules rules,
    required double balance,
    bool dryRun = false,
  }) async {
    bool lateFeeApplied = false;
    bool noticeSent = false;
    bool lockoutTriggered = false;
    DelinquencyStage? newStage;

    // Apply late fees if enabled and conditions met
    if (rules.enableAutoLateFees && 
        tenant.daysLate > rules.gracePeriodDays &&
        stage.currentStage != DelinquencyStage.resolved) {
      if (dryRun) {
        // In dry-run mode, just mark as would-be applied
        lateFeeApplied = true;
      } else {
        lateFeeApplied = await _applyLateFeeIfNeeded(
          tenant: tenant,
          facilityId: facilityId,
          rules: rules,
        );
      }
    }

    // Determine next stage based on days overdue
    if (tenant.daysLate >= rules.lienDays && stage.currentStage != DelinquencyStage.lienFiled) {
      newStage = DelinquencyStage.lienFiled;
    } else if (tenant.daysLate >= rules.finalNoticeDays && stage.currentStage != DelinquencyStage.finalNotice) {
      newStage = DelinquencyStage.finalNotice;
      if (rules.enableAutoNotices) {
        if (dryRun) {
          // In dry-run mode, just mark as would-be sent
          noticeSent = true;
        } else {
          noticeSent = await _sendFinalNotice(tenant, facilityId);
        }
      }
    } else if (tenant.daysLate >= rules.noticeDays && stage.currentStage == DelinquencyStage.overdue) {
      newStage = DelinquencyStage.noticeSent;
      if (rules.enableAutoNotices) {
        if (dryRun) {
          // In dry-run mode, just mark as would-be sent
          noticeSent = true;
        } else {
          noticeSent = await _sendLateNotice(tenant, facilityId);
        }
      }
    }

    // Trigger lockout if enabled and conditions met
    if (rules.enableAutoLockout && 
        tenant.daysLate >= rules.lockoutDays &&
        !lockoutTriggered) {
      if (dryRun) {
        // In dry-run mode, just mark as would-be triggered
        lockoutTriggered = true;
      } else {
        lockoutTriggered = await _triggerLockout(tenant, facilityId);
      }
    }

    // Update stage if changed
    if (newStage != null && newStage != stage.currentStage) {
      await _updateDelinquencyStage(
        facilityId: facilityId,
        stageId: stage.id,
        newStage: newStage,
        tenant: tenant,
      );
    }

    return StageProcessingResult(
      lateFeeApplied: lateFeeApplied,
      noticeSent: noticeSent,
      lockoutTriggered: lockoutTriggered,
    );
  }

  /// Apply late fee if not already applied for this period
  static Future<bool> _applyLateFeeIfNeeded({
    required TenantModel tenant,
    required String facilityId,
    required DelinquencyRules rules,
  }) async {
    try {
      // Check if late fee already applied this month
      final now = DateTime.now();
      final startOfMonth = DateTime(now.year, now.month, 1);

      final ledgerEntries = await LedgerService.getLedgerEntries(
        tenantId: tenant.id,
        facilityId: facilityId,
      );

      final hasLateFeeThisMonth = ledgerEntries.any((entry) {
        if (entry.type != LedgerEntryType.lateFee) return false;
        if (entry.status != LedgerEntryStatus.posted) return false;
        return entry.entryDate.isAfter(startOfMonth) || entry.entryDate.isAtSameMomentAs(startOfMonth);
      });

      if (hasLateFeeThisMonth) {
        return false; // Already applied
      }

      // Calculate late fee
      final lateFee = rules.baseLateFee + 
          ((tenant.daysLate - rules.gracePeriodDays) * rules.dailyLateFee);

      if (lateFee <= 0) return false;

      // Create ledger entry for late fee
      final ledgerEntry = await LedgerService.createLedgerEntry(
        tenantId: tenant.id,
        facilityId: facilityId,
        type: LedgerEntryType.lateFee,
        amount: lateFee,
        description: 'Late Fee - ${tenant.daysLate} days overdue',
        entryDate: DateTime.now(),
        dueDate: DateTime.now(),
        status: LedgerEntryStatus.posted,
        metadata: {
          'daysOverdue': tenant.daysLate,
          'automated': true,
        },
      );

      // Log audit event
      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'delinquency.lateFeeApplied',
        targetType: 'ledgerEntry',
        targetId: ledgerEntry.id,
        tenantId: tenant.id,
        after: {
          'amount': lateFee,
          'daysOverdue': tenant.daysLate,
          'automated': true,
        },
        metadata: {
          'baseLateFee': rules.baseLateFee,
          'dailyLateFee': rules.dailyLateFee,
          'gracePeriodDays': rules.gracePeriodDays,
        },
      );

      // Update delinquency stage late fees
      final stageSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('delinquencyStages')
          .where('tenantId', isEqualTo: tenant.id)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (stageSnapshot.docs.isNotEmpty) {
        await stageSnapshot.docs.first.reference.update({
          'lateFees': FieldValue.increment(lateFee),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      if (kDebugMode) {
        print('✅ [Delinquency] Applied late fee: \$${lateFee.toStringAsFixed(2)} for tenant ${tenant.id}');
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Delinquency] Error applying late fee: $e');
      }
      return false;
    }
  }

  /// Send late notice
  static Future<bool> _sendLateNotice(TenantModel tenant, String facilityId) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) return false;

      final balance = await LedgerService.getLedgerBalance(
        tenantId: tenant.id,
        facilityId: facilityId,
      );

      final subject = 'Late Payment Notice - ${facility.name}';
      final body = '''
Dear ${tenant.name},

This is a notice that your account is past due.

Current Balance: \$${balance.toStringAsFixed(2)}
Days Overdue: ${tenant.daysLate}

Please make payment immediately to avoid additional late fees and potential action.

Thank you,
${facility.name}
''';

      if (tenant.email.isNotEmpty) {
        final emailResult = await EmailService.sendEmail(
          to: tenant.email,
          subject: subject,
          text: body,
          facilityId: facilityId,
        );
        if (!emailResult.success && kDebugMode) {
          print(
            '⚠️ [Delinquency] Late notice email: ${EmailService.staffEmailFailureHint(emailResult)}',
          );
        }
      }

      // Send SMS if email fails or as backup
      if (tenant.phone.isNotEmpty) {
        try {
          await SMSService.sendSMS(
            to: tenant.phone,
            message: 'Late payment notice: Balance \$${balance.toStringAsFixed(2)}, ${tenant.daysLate} days overdue. Please pay immediately.',
            facilityId: facilityId,
          );
        } catch (e) {
          // SMS is optional, don't fail if it doesn't send
        }
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Delinquency] Error sending late notice: $e');
      }
      return false;
    }
  }

  /// Send final notice
  static Future<bool> _sendFinalNotice(TenantModel tenant, String facilityId) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) return false;

      final balance = await LedgerService.getLedgerBalance(
        tenantId: tenant.id,
        facilityId: facilityId,
      );

      final subject = 'FINAL NOTICE - Immediate Payment Required - ${facility.name}';
      final body = '''
Dear ${tenant.name},

This is a FINAL NOTICE regarding your past due account.

Current Balance: \$${balance.toStringAsFixed(2)}
Days Overdue: ${tenant.daysLate}

Your account is severely past due. Immediate payment is required to avoid further action, including potential lien filing.

Please contact us immediately to resolve this matter.

Thank you,
${facility.name}
''';

      if (tenant.email.isNotEmpty) {
        final emailResult = await EmailService.sendEmail(
          to: tenant.email,
          subject: subject,
          text: body,
          facilityId: facilityId,
        );
        if (!emailResult.success && kDebugMode) {
          print(
            '⚠️ [Delinquency] Final notice email: ${EmailService.staffEmailFailureHint(emailResult)}',
          );
        }
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Delinquency] Error sending final notice: $e');
      }
      return false;
    }
  }

  /// Trigger lockout (disable gate access)
  static Future<bool> _triggerLockout(TenantModel tenant, String facilityId) async {
    try {
      // Get gate access for facility and filter by tenant
      final gateAccessSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess')
          .where('tenantId', isEqualTo: tenant.id)
          .where('isActive', isEqualTo: true)
          .get();

      final deactivatedAccessIds = <String>[];
      for (final doc in gateAccessSnapshot.docs) {
        await GateAccessService.updateGateAccess(
          facilityId: facilityId,
          accessId: doc.id,
          isActive: false,
        );
        deactivatedAccessIds.add(doc.id);
      }

      // Log audit event
      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'delinquency.lockoutTriggered',
        targetType: 'tenant',
        targetId: tenant.id,
        tenantId: tenant.id,
        after: {
          'lockoutStatus': 'locked',
          'daysLate': tenant.daysLate,
        },
        metadata: {
          'automated': true,
          'deactivatedAccessIds': deactivatedAccessIds,
        },
      );

      if (kDebugMode) {
        print('✅ [Delinquency] Lockout triggered for tenant ${tenant.id}');
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Delinquency] Error triggering lockout: $e');
      }
      return false;
    }
  }

  /// Update delinquency stage
  static Future<void> _updateDelinquencyStage({
    required String facilityId,
    required String stageId,
    required DelinquencyStage newStage,
    required TenantModel tenant,
  }) async {
    final updates = <String, dynamic>{
      'currentStage': newStage.name,
      'stageDate': FieldValue.serverTimestamp(),
      'daysOverdue': tenant.daysLate,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    // Set stage-specific dates
    switch (newStage) {
      case DelinquencyStage.noticeSent:
        updates['noticeSentDate'] = FieldValue.serverTimestamp();
        break;
      case DelinquencyStage.finalNotice:
        updates['finalNoticeSentDate'] = FieldValue.serverTimestamp();
        break;
      case DelinquencyStage.lienFiled:
        updates['lienFiledDate'] = FieldValue.serverTimestamp();
        break;
      case DelinquencyStage.auctionScheduled:
        updates['auctionScheduledDate'] = FieldValue.serverTimestamp();
        break;
      case DelinquencyStage.auctionComplete:
        updates['auctionCompleteDate'] = FieldValue.serverTimestamp();
        break;
      case DelinquencyStage.resolved:
        updates['resolvedDate'] = FieldValue.serverTimestamp();
        break;
      default:
        break;
    }

    await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('delinquencyStages')
        .doc(stageId)
        .update(updates);
  }

  /// Check and resolve delinquency if balance is paid
  static Future<void> _checkAndResolveDelinquency(
    TenantModel tenant,
    String facilityId,
  ) async {
    final stageSnapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('delinquencyStages')
        .where('tenantId', isEqualTo: tenant.id)
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (stageSnapshot.docs.isNotEmpty) {
      final stage = DelinquencyStageModel.fromFirestore(stageSnapshot.docs.first);
      if (stage.currentStage != DelinquencyStage.resolved) {
        await _updateDelinquencyStage(
          facilityId: facilityId,
          stageId: stage.id,
          newStage: DelinquencyStage.resolved,
          tenant: tenant,
        );
      }
    }
  }
}

/// Delinquency rules configuration
class DelinquencyRules {
  final int gracePeriodDays;
  final double baseLateFee;
  final double dailyLateFee;
  final int noticeDays; // Days overdue before sending notice
  final int finalNoticeDays; // Days overdue before sending final notice
  final int lienDays; // Days overdue before filing lien
  final int lockoutDays; // Days overdue before lockout
  final bool enableAutoLateFees;
  final bool enableAutoNotices;
  final bool enableAutoLockout;

  const DelinquencyRules({
    this.gracePeriodDays = 3,
    this.baseLateFee = 25.0,
    this.dailyLateFee = 5.0,
    this.noticeDays = 7,
    this.finalNoticeDays = 14,
    this.lienDays = 30,
    this.lockoutDays = 45,
    this.enableAutoLateFees = true,
    this.enableAutoNotices = true,
    this.enableAutoLockout = false,
  });
}

/// Result of processing a delinquency stage
class StageProcessingResult {
  final bool lateFeeApplied;
  final bool noticeSent;
  final bool lockoutTriggered;

  const StageProcessingResult({
    this.lateFeeApplied = false,
    this.noticeSent = false,
    this.lockoutTriggered = false,
  });
}

/// Result of delinquency processing
class DelinquencyProcessingResult {
  final bool success;
  final int? processedCount;
  final int? lateFeeAppliedCount;
  final int? noticeSentCount;
  final int? lockoutCount;
  final int? errorCount;
  final List<String> errors;
  final String? error;

  DelinquencyProcessingResult({
    required this.success,
    this.processedCount,
    this.lateFeeAppliedCount,
    this.noticeSentCount,
    this.lockoutCount,
    this.errorCount,
    this.errors = const [],
    this.error,
  });
}

