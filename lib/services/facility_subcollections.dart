import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// A facility's tenants and units collections, opened in one place.
///
/// The tenant and unit reads behind the dashboard, the Units list, the
/// facility cards and the tenant limit all start here, so tests can point
/// that production code at a fake collection instead of testing a copy of it.
class FacilitySubcollections {
  FacilitySubcollections._();

  /// Most docs one read of a facility's tenants or units returns.
  ///
  /// Tenant reads were capped at 250 and unit reads at 400, both ordered by a
  /// field Firestore leaves out when a doc lacks it, and archived units used
  /// up the unit cap. Every tenant or unit past the cap, and every doc without
  /// the field, silently fell out of the counts. This bound only guards
  /// against a runaway facility (a load test once wrote ~30,000 tenant docs
  /// to one), and reaching it is reported, not silent.
  static const int readLimit = 5000;

  static CollectionReference<Map<String, dynamic>> tenants(String facilityId) =>
      _open(facilityId, 'tenants');

  /// Tenants that count as active: `isActive` is exactly true. The facility
  /// stats Cloud Function and the server jobs select active tenants with this
  /// same filter, and `TenantModel.isActiveField` reads a doc the same way.
  static Query<Map<String, dynamic>> activeTenants(String facilityId) =>
      tenants(facilityId).where('isActive', isEqualTo: true);

  static CollectionReference<Map<String, dynamic>> units(String facilityId) =>
      _open(facilityId, 'units');

  static CollectionReference<Map<String, dynamic>> Function(
    String facilityId,
    String name,
  ) _open = _openInFirestore;

  /// Serves [tenants] and [units] from [open] instead of Firestore; null
  /// restores Firestore.
  @visibleForTesting
  static void overrideForTesting(
    CollectionReference<Map<String, dynamic>> Function(
      String facilityId,
      String name,
    )? open,
  ) {
    _open = open ?? _openInFirestore;
  }

  static CollectionReference<Map<String, dynamic>> _openInFirestore(
    String facilityId,
    String name,
  ) {
    return FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .collection(name);
  }

  static final Set<String> _readLimitReported = <String>{};

  /// Reports a read of [name] for [facilityId] that came back with
  /// [readLimit] docs, once per facility and collection: the caller only
  /// sees the first [readLimit].
  static void reportIfReadLimitReached(
    String facilityId,
    String name,
    int docCount,
  ) {
    if (docCount < readLimit || !_readLimitReported.add('$name/$facilityId')) {
      return;
    }
    final message = 'Facility $facilityId has at least $readLimit $name docs; '
        'lists, occupancy and dashboard counts only see the first $readLimit.';
    debugPrint('⚠️ [FacilitySubcollections] $message');
    // Reaches Sentry through main.dart's FlutterError.onError.
    FlutterError.reportError(FlutterErrorDetails(
      exception: StateError(message),
      stack: StackTrace.current,
      library: 'facility_subcollections',
    ));
  }
}
