import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/utils/sms_consent.dart';

/// One tenant's consent write and the audit row that goes with it.
class SmsConsentWrite {
  final String tenantId;
  final Map<String, dynamic> fields;
  final AuditLogEntry audit;

  const SmsConsentWrite({
    required this.tenantId,
    required this.fields,
    required this.audit,
  });
}

/// Commits consent writes. A seam so tests can see what would be written.
abstract class SmsConsentWriter {
  Future<void> commit(String facilityId, List<SmsConsentWrite> writes);
}

/// Firestore batches: each tenant's update and its audit row land together
/// or not at all. Two writes per tenant, under the 500-write batch limit.
class FirestoreSmsConsentWriter implements SmsConsentWriter {
  static const tenantsPerBatch = 200;

  final FirebaseFirestore _db;
  FirestoreSmsConsentWriter([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  @override
  Future<void> commit(String facilityId, List<SmsConsentWrite> writes) async {
    final facility = _db.collection('facilities').doc(facilityId);
    for (var i = 0; i < writes.length; i += tenantsPerBatch) {
      final batch = _db.batch();
      final end = (i + tenantsPerBatch).clamp(0, writes.length);
      for (final w in writes.sublist(i, end)) {
        batch.update(facility.collection('tenants').doc(w.tenantId), {
          ...w.fields,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        batch.set(facility.collection('auditLogs').doc(), w.audit.toFirestore());
      }
      await batch.commit();
    }
  }
}

class SmsConsentBulkResult {
  final SmsConsentBulkPlan plan;
  final SmsConsentUpdate update;
  const SmsConsentBulkResult(this.plan, this.update);

  int get updated => plan.toUpdate.length;
}

class SmsConsentService {
  SmsConsentService._();

  /// Records or removes consent for [tenants] (the owner's selection). Only
  /// the tenants [planSmsConsentBulk] picks are written: a tenant's own
  /// opt-out is never overridden, tenants with no mobile number are skipped,
  /// and a consent already on file keeps its original date.
  static Future<SmsConsentBulkResult> applyBulk({
    required String facilityId,
    required List<TenantModel> tenants,
    required SmsConsentUpdate update,
    SmsConsentWriter? writer,
    String? actingUid,
    String? actingEmail,
  }) async {
    final user = actingUid == null ? FirebaseAuth.instance.currentUser : null;
    final uid = actingUid ?? user?.uid;
    if (uid == null) throw Exception('Not signed in');
    final email = actingEmail ?? user?.email;

    final plan = planSmsConsentBulk(tenants, grant: update.grant);
    if (plan.toUpdate.isEmpty) return SmsConsentBulkResult(plan, update);

    final fields = update.fields(actingUid: uid);
    final now = DateTime.now();
    final eventType =
        update.grant ? 'tenant.smsConsentRecorded' : 'tenant.smsConsentRemoved';
    final writes = [
      for (final t in plan.toUpdate)
        SmsConsentWrite(
          tenantId: t.id,
          fields: fields,
          audit: AuditLogEntry(
            eventType: eventType,
            actorUid: uid,
            actorEmail: email,
            targetType: 'tenant',
            targetId: t.id,
            facilityId: facilityId,
            tenantId: t.id,
            before: {
              'smsOptOut': t.smsOptOut,
              'smsConsentStatus': t.smsConsentStatus,
              if (t.smsOptInDate != null)
                'smsOptInDate': t.smsOptInDate!.toIso8601String(),
              if (t.smsConsentSource != null)
                'smsConsentSource': t.smsConsentSource,
            },
            after: update.auditSummary(),
            timestamp: now,
            metadata: {
              'bulk': true,
              'selectedCount': tenants.length,
              'updatedCount': plan.toUpdate.length,
            },
          ),
        ),
    ];
    await (writer ?? FirestoreSmsConsentWriter()).commit(facilityId, writes);
    return SmsConsentBulkResult(plan, update);
  }
}
