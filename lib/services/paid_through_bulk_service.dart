import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/utils/paid_through.dart';

/// One tenant's paidThrough write and the audit row that goes with it.
class PaidThroughWrite {
  final String tenantId;

  /// The tenant fields, as the single Set Paid Through dialog writes them
  /// through TenantService.updateTenant (the writer adds updatedAt).
  final Map<String, dynamic> fields;
  final AuditLogEntry audit;

  const PaidThroughWrite({
    required this.tenantId,
    required this.fields,
    required this.audit,
  });
}

/// Some batches committed and a later one failed: [committed] tenants were
/// saved, the rest of [total] were not.
class PaidThroughPartialFailure implements Exception {
  final int committed;
  final int total;
  final Object cause;

  const PaidThroughPartialFailure({
    required this.committed,
    required this.total,
    required this.cause,
  });

  @override
  String toString() =>
      'PaidThroughPartialFailure($committed of $total saved): $cause';
}

/// Commits paidThrough writes. A seam so tests can see what would be written.
abstract class PaidThroughWriter {
  /// Throws [PaidThroughPartialFailure] when it stops part way.
  Future<void> commit(String facilityId, List<PaidThroughWrite> writes);
}

/// Reads the tenants as stored now. A seam like [PaidThroughWriter].
abstract class PaidThroughTenantReader {
  Future<List<TenantModel>> read(String facilityId, List<String> tenantIds);
}

/// Firestore batches: each tenant's update and its audit row land together
/// or not at all. Two writes per tenant, under the 500-write batch limit.
/// Batches go one after another, so a failure part way leaves the earlier
/// ones saved; that count is reported.
class FirestorePaidThroughWriter implements PaidThroughWriter {
  static const tenantsPerBatch = 200;

  final FirebaseFirestore _db;
  FirestorePaidThroughWriter([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  @override
  Future<void> commit(String facilityId, List<PaidThroughWrite> writes) async {
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
        throw PaidThroughPartialFailure(
            committed: committed, total: writes.length, cause: e);
      }
      committed += chunk.length;
    }
  }
}

class FirestorePaidThroughTenantReader implements PaidThroughTenantReader {
  final FirebaseFirestore _db;
  FirestorePaidThroughTenantReader([FirebaseFirestore? db])
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

class PaidThroughBulkService {
  PaidThroughBulkService._();

  /// Marks [tenants] (the owner's selection) paid through the end of
  /// [month] [year].
  ///
  /// For an owner moving over from a paper ledger: everyone who is paid up
  /// can be marked so in one step, instead of opening each tenant. The
  /// tenants are read again just before writing and the plan is made from
  /// that read, so a payment recorded while the dialog was open (which
  /// moves paidThrough forward) is not walked back. A tenant already paid
  /// through a later date is left as they are.
  ///
  /// Throws [PaidThroughPartialFailure] when some batches were saved and a
  /// later one failed.
  static Future<PaidThroughBulkPlan> applyBulk({
    required String facilityId,
    required List<TenantModel> tenants,
    required int year,
    required int month,
    PaidThroughWriter? writer,
    PaidThroughTenantReader? reader,
    String? actingUid,
    String? actingEmail,
  }) async {
    final user = actingUid == null ? FirebaseAuth.instance.currentUser : null;
    final uid = actingUid ?? user?.uid;
    if (uid == null) throw Exception('Not signed in');
    final email = actingEmail ?? user?.email;

    final fresh = await (reader ?? FirestorePaidThroughTenantReader())
        .read(facilityId, [for (final t in tenants) t.id]);
    final plan = planPaidThroughBulk(fresh, year: year, month: month);
    if (plan.toUpdate.isEmpty) return plan;

    final value = plan.paidThrough;
    final now = DateTime.now();
    final writes = [
      for (final t in plan.toUpdate)
        PaidThroughWrite(
          tenantId: t.id,
          fields: {'paidThrough': Timestamp.fromDate(value)},
          // The same event the single dialog logs (TenantService.updateTenant).
          audit: AuditLogEntry(
            eventType: 'tenant.edited',
            actorUid: uid,
            actorEmail: email,
            targetType: 'tenant',
            targetId: t.id,
            facilityId: facilityId,
            tenantId: t.id,
            before: {
              'paidThrough': t.paidThrough?.toIso8601String(),
            },
            after: {'paidThrough': value.toIso8601String()},
            timestamp: now,
            metadata: {
              'fieldsChanged': ['paidThrough', 'updatedAt'],
              'bulk': true,
              'selectedCount': tenants.length,
              'updatedCount': plan.toUpdate.length,
            },
          ),
        ),
    ];
    await (writer ?? FirestorePaidThroughWriter()).commit(facilityId, writes);
    return plan;
  }
}
