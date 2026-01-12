import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_model.dart';
import '../models/tenant_model.dart';
import '../models/payment_model.dart';
import '../models/contract_model.dart';
import '../models/unit_model.dart';
import 'error_handling_service.dart';

class DataConsistencyService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Check data consistency for a facility
  static Future<ConsistencyReport> checkFacilityConsistency(String facilityId) async {
    final report = ConsistencyReport(facilityId: facilityId);
    
    try {
      if (kDebugMode) {
        print('🔄 Checking data consistency for facility: $facilityId');
      }

      // Check facility exists
      final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
      if (!facilityDoc.exists) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.missingData,
          severity: ConsistencySeverity.critical,
          message: 'Facility document does not exist',
          entityType: 'facility',
          entityId: facilityId,
          facilityId: facilityId,
          resolution: 'Recreate the facility or remove references to this facility from other records.',
        ));
        return report;
      }

      final facility = FacilityModel.fromFirestore(facilityDoc);
      
      // Check facility data integrity
      _checkFacilityDataIntegrity(facility, report, facilityId);
      
      // Check related entities
      await _checkRelatedEntities(facilityId, report);
      
      // Check orphaned data
      await _checkOrphanedData(facilityId, report);
      
      if (kDebugMode) {
        print('✅ Data consistency check complete for facility: $facilityId');
        print('Issues found: ${report.issues.length}');
      }
      
    } catch (e) {
      final error = ErrorHandlingService.handleGenericError(e);
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.systemError,
        severity: ConsistencySeverity.critical,
        message: 'Failed to check data consistency: ${error.message}',
        entityType: 'facility',
        entityId: facilityId,
        facilityId: facilityId,
        resolution: 'Retry the integrity check. If the issue persists, review the error log for stack traces.',
      ));
    }
    
    return report;
  }

  // Check facility data integrity
  static void _checkFacilityDataIntegrity(FacilityModel facility, ConsistencyReport report, String facilityId) {
    // Check required fields
    if (facility.name.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Facility name is empty',
        entityType: 'facility',
        entityId: facility.id,
        facilityId: facilityId,
        resolution: 'Edit the facility details and provide a facility name.',
      ));
    }

    if (facility.address == null || facility.address!.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Facility address is empty',
        entityType: 'facility',
        entityId: facility.id,
        facilityId: facilityId,
        resolution: 'Add a mailing address to the facility profile so automated messages have proper contact info.',
      ));
    }

    // Check email format if provided
    if (facility.email != null && facility.email!.isNotEmpty) {
      final emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
      if (!emailRegex.hasMatch(facility.email!)) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.invalidData,
          severity: ConsistencySeverity.medium,
          message: 'Facility email format is invalid',
          entityType: 'facility',
          entityId: facility.id,
          facilityId: facilityId,
          resolution: 'Update the facility email to a valid format (example@domain.com).',
        ));
      }
    }

    // Check phone format if provided
    if (facility.phone != null && facility.phone!.isNotEmpty) {
      final phoneRegex = RegExp(r'^\+?[\d\s\-\(\)]+$');
      if (!phoneRegex.hasMatch(facility.phone!)) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.invalidData,
          severity: ConsistencySeverity.medium,
          message: 'Facility phone format is invalid',
          entityType: 'facility',
          entityId: facility.id,
          facilityId: facilityId,
          resolution: 'Update the facility phone number using digits only (optionally include country code).',
        ));
      }
    }
  }

  // Check related entities
  static Future<void> _checkRelatedEntities(String facilityId, ConsistencyReport report) async {
    // Check tenants
    final tenantsSnapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .get();

    for (final tenantDoc in tenantsSnapshot.docs) {
      try {
        final tenant = TenantModel.fromFirestore(tenantDoc);
        _checkTenantDataIntegrity(tenant, report, facilityId);
      } catch (e) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.invalidData,
          severity: ConsistencySeverity.high,
          message: 'Failed to parse tenant data: ${e.toString()}',
          entityType: 'tenant',
          entityId: tenantDoc.id,
          facilityId: facilityId,
        resolution: 'Open this tenant in the app and re-save their details to regenerate a clean record.',
        ));
      }
    }

    // Check units
    final unitsSnapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .get();

    for (final unitDoc in unitsSnapshot.docs) {
      try {
        final unit = UnitModel.fromFirestore(unitDoc);
        _checkUnitDataIntegrity(unit, report, facilityId);
      } catch (e) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.invalidData,
          severity: ConsistencySeverity.high,
          message: 'Failed to parse unit data: ${e.toString()}',
          entityType: 'unit',
          entityId: unitDoc.id,
          facilityId: facilityId,
          resolution: 'Inspect the unit record for missing fields (e.g., rate, dimensions) and update it.',
        ));
      }
    }

    // Check contracts
    final contractsSnapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('contracts')
        .get();

    for (final contractDoc in contractsSnapshot.docs) {
      try {
        final contract = ContractModel.fromFirestore(contractDoc);
        _checkContractDataIntegrity(contract, report, facilityId);
      } catch (e) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.invalidData,
          severity: ConsistencySeverity.high,
          message: 'Failed to parse contract data: ${e.toString()}',
          entityType: 'contract',
          entityId: contractDoc.id,
          facilityId: facilityId,
          resolution: 'Open the contract editor and review required fields; re-save once corrected.',
        ));
      }
    }

    // Check payments
    final paymentsSnapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('payments')
        .get();

    for (final paymentDoc in paymentsSnapshot.docs) {
      try {
        final payment = PaymentModel.fromFirestore(paymentDoc);
        _checkPaymentDataIntegrity(payment, report, facilityId);
      } catch (e) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.invalidData,
          severity: ConsistencySeverity.high,
          message: 'Failed to parse payment data: ${e.toString()}',
          entityType: 'payment',
          entityId: paymentDoc.id,
          facilityId: facilityId,
          resolution: 'Review this payment entry for missing or malformed fields and correct it manually.',
        ));
      }
    }
  }

  // Check tenant data integrity
  static void _checkTenantDataIntegrity(TenantModel tenant, ConsistencyReport report, String facilityId) {
    if (tenant.name.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Tenant name is empty',
        entityType: 'tenant',
        entityId: tenant.id,
        facilityId: facilityId,
        resolution: 'Open the tenant profile and add the tenant’s first and last name.',
      ));
    }

    if (tenant.email.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Tenant email is empty',
        entityType: 'tenant',
        entityId: tenant.id,
        facilityId: facilityId,
      ));
    } else {
      final emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
      if (!emailRegex.hasMatch(tenant.email)) {
        report.addIssue(ConsistencyIssue(
          type: ConsistencyIssueType.invalidData,
          severity: ConsistencySeverity.medium,
          message: 'Tenant email format is invalid',
          entityType: 'tenant',
          entityId: tenant.id,
          facilityId: facilityId,
          resolution: 'Update the tenant email to a valid format (example@domain.com).',
        ));
      }
    }

    if (tenant.phone.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Tenant phone is empty',
        entityType: 'tenant',
        entityId: tenant.id,
        facilityId: facilityId,
        resolution: 'Add a primary phone number for the tenant so reminders and gate access work correctly.',
      ));
    }
  }

  // Check unit data integrity
  static void _checkUnitDataIntegrity(UnitModel unit, ConsistencyReport report, String facilityId) {
    if (unit.unitNumber.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Unit number is empty',
        entityType: 'unit',
        entityId: unit.id,
        facilityId: facilityId,
        resolution: 'Edit the unit and assign a unit number so staff can identify it.',
      ));
    }

    if (unit.monthlyRate <= 0) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Unit monthly rate must be greater than 0',
        entityType: 'unit',
        entityId: unit.id,
        facilityId: facilityId,
        resolution: 'Update the unit rate to a positive value to ensure invoices are generated correctly.',
      ));
    }

    if (unit.dimensions == null || unit.dimensions!.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.medium,
        message: 'Unit dimensions are empty',
        entityType: 'unit',
        entityId: unit.id,
        facilityId: facilityId,
        resolution: 'Add unit dimensions (e.g., 10x15) so size filters and marketing details are accurate.',
      ));
    }
  }

  // Check contract data integrity
  static void _checkContractDataIntegrity(ContractModel contract, ConsistencyReport report, String facilityId) {
    if (contract.tenantId.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Contract tenant ID is empty',
        entityType: 'contract',
        entityId: contract.id,
        facilityId: facilityId,
        resolution: 'Edit the contract and select the tenant this agreement belongs to.',
      ));
    }

    if (contract.title.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Contract title is empty',
        entityType: 'contract',
        entityId: contract.id,
        facilityId: facilityId,
        resolution: 'Provide a descriptive contract title (e.g., “Unit 101 Lease – 2025”).',
      ));
    }

    if (contract.description.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.medium,
        message: 'Contract description is empty',
        entityType: 'contract',
        entityId: contract.id,
        facilityId: facilityId,
        resolution: 'Add a short contract description so staff know the agreement purpose.',
      ));
    }

    if (contract.expiresAt != null && contract.createdAt.isAfter(contract.expiresAt!)) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Contract creation date is after expiration date',
        entityType: 'contract',
        entityId: contract.id,
        facilityId: facilityId,
        resolution: 'Review the contract start and end dates; expiration must be after creation.',
      ));
    }
  }

  // Check payment data integrity
  static void _checkPaymentDataIntegrity(PaymentModel payment, ConsistencyReport report, String facilityId) {
    if (payment.tenantId.isEmpty) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Payment tenant ID is empty',
        entityType: 'payment',
        entityId: payment.id,
        facilityId: facilityId,
        resolution: 'Edit or delete this payment so it references a valid tenant.',
      ));
    }

    if (payment.amount <= 0) {
      report.addIssue(ConsistencyIssue(
        type: ConsistencyIssueType.invalidData,
        severity: ConsistencySeverity.high,
        message: 'Payment amount must be greater than 0',
        entityType: 'payment',
        entityId: payment.id,
        facilityId: facilityId,
        resolution: 'Update the payment amount to a positive value or remove the incorrect payment.',
      ));
    }
  }

  // Check orphaned data
  static Future<void> _checkOrphanedData(String facilityId, ConsistencyReport report) async {
    // Check for tenants without valid facility reference
    final tenantsSnapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .get();

    for (final tenantDoc in tenantsSnapshot.docs) {
      final tenant = TenantModel.fromFirestore(tenantDoc);
      
      // Check if tenant has contracts but no valid unit references
      final contractsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .where('tenantId', isEqualTo: tenant.id)
          .get();

      for (final contractDoc in contractsSnapshot.docs) {
        final contract = ContractModel.fromFirestore(contractDoc);
        
        // Check if contract has valid facility reference
        final facilityDoc = await _firestore
            .collection('facilities')
            .doc(contract.facilityId)
            .get();

        if (!facilityDoc.exists) {
          report.addIssue(ConsistencyIssue(
            type: ConsistencyIssueType.orphanedData,
            severity: ConsistencySeverity.high,
            message: 'Contract references non-existent facility',
            entityType: 'contract',
            entityId: contract.id,
            facilityId: facilityId,
          resolution: 'Either delete this contract or update it to reference an existing facility.',
          ));
        }
      }
    }
  }

  // Fix data consistency issues
  static Future<ConsistencyFixResult> fixConsistencyIssues(ConsistencyReport report) async {
    if (kDebugMode) {
      print('🔄 Fixing ${report.issues.length} consistency issues');
    }

    int autoFixed = 0;
    final manualIssues = <ConsistencyIssue>[];

    for (final issue in report.issues) {
      try {
        final handled = await _fixIssue(issue);
        if (handled) {
          autoFixed++;
        } else {
          manualIssues.add(issue);
        }
      } catch (e) {
        if (kDebugMode) {
          print('❌ Failed to fix issue ${issue.id}: ${e.toString()}');
        }
        manualIssues.add(issue);
      }
    }
    return ConsistencyFixResult(autoFixed: autoFixed, manualIssues: manualIssues);
  }

  // Fix individual issue
  static Future<bool> _fixIssue(ConsistencyIssue issue) async {
    switch (issue.type) {
      case ConsistencyIssueType.missingData:
        // Cannot fix missing data automatically
        return false;
      case ConsistencyIssueType.invalidData:
        // Some invalid data can be fixed
        return await _fixInvalidData(issue);
      case ConsistencyIssueType.orphanedData:
        // Remove orphaned data
        return await _fixOrphanedData(issue);
      case ConsistencyIssueType.systemError:
        // Cannot fix system errors automatically
        return false;
    }
  }

  // Fix invalid data
  static Future<bool> _fixInvalidData(ConsistencyIssue issue) async {
    // This would contain specific logic to fix invalid data
    // For now, we'll just log that we attempted to fix it
    if (kDebugMode) {
      print('🔧 Attempting to fix invalid data for ${issue.entityType}: ${issue.entityId}');
    }
    return false;
  }

  // Fix orphaned data
  static Future<bool> _fixOrphanedData(ConsistencyIssue issue) async {
    if (issue.entityType == 'contract') {
      // Delete orphaned contract
      await _firestore.collection('facilities').doc(issue.facilityId).collection('contracts').doc(issue.entityId).delete();
      if (kDebugMode) {
        print('🗑️ Deleted orphaned contract: ${issue.entityId}');
      }
      return true;
    }
    return false;
  }
}

class ConsistencyFixResult {
  final int autoFixed;
  final List<ConsistencyIssue> manualIssues;

  ConsistencyFixResult({
    required this.autoFixed,
    required this.manualIssues,
  });

  int get manualCount => manualIssues.length;
  int get total => autoFixed + manualIssues.length;
}

enum ConsistencyIssueType {
  missingData,
  invalidData,
  orphanedData,
  systemError,
}

enum ConsistencySeverity {
  low,
  medium,
  high,
  critical,
}

class ConsistencyIssue {
  final String id;
  final ConsistencyIssueType type;
  final ConsistencySeverity severity;
  final String message;
  final String entityType;
  final String entityId;
  final String facilityId;
  final DateTime timestamp;
  final String? resolution;

  ConsistencyIssue({
    required this.type,
    required this.severity,
    required this.message,
    required this.entityType,
    required this.entityId,
    required this.facilityId,
    this.resolution,
  })  : id = DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp = DateTime.now();

  @override
  String toString() {
    return 'ConsistencyIssue(id: $id, type: $type, severity: $severity, message: $message)';
  }
}

class ConsistencyReport {
  final String facilityId;
  final List<ConsistencyIssue> issues = [];
  final DateTime createdAt = DateTime.now();

  ConsistencyReport({required this.facilityId});

  void addIssue(ConsistencyIssue issue) {
    issues.add(issue);
  }

  bool get hasIssues => issues.isNotEmpty;
  bool get hasCriticalIssues => issues.any((issue) => issue.severity == ConsistencySeverity.critical);
  bool get hasHighSeverityIssues => issues.any((issue) => 
    issue.severity == ConsistencySeverity.critical || 
    issue.severity == ConsistencySeverity.high
  );

  List<ConsistencyIssue> getIssuesByType(ConsistencyIssueType type) {
    return issues.where((issue) => issue.type == type).toList();
  }

  List<ConsistencyIssue> getIssuesBySeverity(ConsistencySeverity severity) {
    return issues.where((issue) => issue.severity == severity).toList();
  }

  Map<ConsistencyIssueType, int> getIssueCounts() {
    final counts = <ConsistencyIssueType, int>{};
    for (final issue in issues) {
      counts[issue.type] = (counts[issue.type] ?? 0) + 1;
    }
    return counts;
  }

  Map<ConsistencySeverity, int> getSeverityCounts() {
    final counts = <ConsistencySeverity, int>{};
    for (final issue in issues) {
      counts[issue.severity] = (counts[issue.severity] ?? 0) + 1;
    }
    return counts;
  }
}
