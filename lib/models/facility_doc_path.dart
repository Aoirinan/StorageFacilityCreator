import 'package:cloud_firestore/cloud_firestore.dart';

/// The facilityId a model read from [doc] should carry: the stored field, or
/// when that is missing or empty, the facility the doc sits under.
///
/// A doc written without a facilityId read back with ''. The pages act
/// through model.facilityId (process a payment, a contract's actions), and
/// those reads and writes went to `facilities//...` and failed.
String facilityIdOf(DocumentSnapshot doc, Object? storedFacilityId) {
  if (storedFacilityId is String && storedFacilityId.isNotEmpty) {
    return storedFacilityId;
  }
  return facilityIdFromPath(doc.reference);
}

/// The id of the facility a `facilities/{facilityId}/<collection>/{id}` doc
/// is stored under, or '' for a doc stored anywhere else. Checked all the
/// way up: for a doc in a tenant's own subcollection the parent of its
/// collection is the tenant, whose id is not a facility's.
String facilityIdFromPath(DocumentReference doc) {
  final facility = doc.parent.parent;
  if (facility == null) return '';
  final facilities = facility.parent;
  if (facilities.id != 'facilities' || facilities.parent != null) return '';
  return facility.id;
}
