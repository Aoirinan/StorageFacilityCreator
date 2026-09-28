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

/// Some batches committed and a later one failed: [committed] tenants were
/// saved, the rest of [total] were not.
class SmsConsentPartialFailure implements Exception {
  final int committed;
  final int total;
  final Object cause;

  const SmsConsentPartialFailure({
    required this.committed,
    required this.total,
    required this.cause,
  });

  @override
  String toString() =>
      'SmsConsentPartialFailure($committed of $total saved): $cause';
}

/// Commits consent writes. A seam so tests can see what would be written.
abstract class SmsConsentWriter {
  /// Throws [SmsConsentPartialFailure] when it stops part way.
  Future<void> commit(String facilityId, List<SmsConsentWrite> writes);
}

/// Reads the tenants as stored now. A seam like [SmsConsentWriter].
abstract class SmsConsentTenantReader {
  Future<List<TenantModel>> read(String facilityId, List<String> tenantIds);
}

/// Firestore batches: each tenant's update and its audit row land together
/// or not at all. Two writes per tenant, under the 500-write batch limit.
/// Batches go one after another, so a failure part way leaves the earlier
/// ones saved; that count is reported.
class FirestoreSmsConsentWriter implements SmsConsentWriter {
  static const tenantsPerBatch = 200;

  final FirebaseFirestore _db;
  FirestoreSmsConsentWriter([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  @override
  Future<void> commit(String facilityId, List<SmsConsentWrite> writes) async {
    final facility = _db.collection('facilities').doc(facilityId);
    var committed = 0;
    for (var i = 0; i < writes.length; i += tenantsPerBatch) {
      final end = (i + tenantsPerBatch).clamp(0, writes.length);
      final chunk = writes.sublist(i, end);
      final batch = _db.batch();
      for (final w in chunk) {
        batch.update(facility.collection('tenants').doc(w.tenantId), {
          ...w.fields,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        batch.set(facility.collection('auditLogs').doc(), w.audit.toFirestore());
      }
      try {
        await batch.commit();
      } catch (e) {
        throw SmsConsentPartialFailure(
            committed: committed, total: writes.length, cause: e);
      }
      committed += chunk.length;
    }
  }
}

class FirestoreSmsConsentTenantReader implements SmsConsentTenantReader {
  final FirebaseFirestore _db;
  FirestoreSmsConsentTenantReader([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  @override
  Future<List<TenantModel>> read(String facilityId, List<String> tenantIds) async {
    final tenants = _db.collection('facilities').doc(facilityId).collection('tenants');
    final out = <TenantModel>[];
    // whereIn takes at most 30 values.
    for (var i = 0; i < tenantIds.length; i += 30) {
      final ids = tenantIds.sublist(i, (i + 30).clamp(0, tenantIds.length));
      final snap = await tenants
          .where(FieldPath.documentId, whereIn: ids)
          .get(const GetOptions(source: Source.server));
      out.addAll(snap.docs.map(TenantModel.fromFirestore));
    }
    return out;
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

  /// Records or removes consent for [tenants] (the owner's selection).
  ///
  /// The tenants are read again just before writing, and the plan is made
  /// from that read, not from the list the owner was looking at: a tenant
  /// who texted STOP while the dialog was open is skipped, not opted back
  /// in. (The Firestore rules refuse that write too, as a backstop.) Only the
  /// tenants [planSmsConsentBulk] picks are written: a tenant's own opt-out
  /// is never overridden, tenants with no textable number are skipped, and a
  /// consent already on file keeps its original date.
  ///
  /// Throws [SmsConsentPartialFailure] when some batches were saved and a
  /// later one failed.
  static Future<SmsConsentBulkResult> applyBulk({
    required String facilityId,
    required List<TenantModel> tenants,
    required SmsConsentUpdate update,
    SmsConsentWriter? writer,
    SmsConsentTenantReader? reader,
    String? actingUid,
    String? actingEmail,
  }) async {
    final user = actingUid == null ? FirebaseAuth.instance.currentUser : null;
    final uid = actingUid ?? user?.uid;
    if (uid == null) throw Exception('Not signed in');
    final email = actingEmail ?? user?.email;

    final fresh = await (reader ?? FirestoreSmsConsentTenantReader())
        .read(facilityId, [for (final t in tenants) t.id]);
    final plan = planSmsConsentBulk(fresh, grant: update.grant);
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
