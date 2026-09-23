import 'package:sfcapp/models/facility_model.dart';

/// How recently a facility must have been created to count as the one an
/// attempt that reported an error made anyway.
const facilityCreateRecoveryWindow = Duration(minutes: 5);

/// Added to the error when a create failed and no facility it made could be
/// found: the write may still land (or have landed where the re-check could
/// not see it), and Create is live again.
const facilityCreateUnconfirmedHint =
    'Check Facilities before retrying: the facility may have been created.';

/// The facility a create attempt that reported an error may have made
/// anyway: one this user owns, named [name], created within
/// [facilityCreateRecoveryWindow] of [now]. The newest when there are
/// several; null when there is none.
///
/// This replaced "the last facility in the list", which is sorted by name,
/// so a failed create went on as whichever facility sorted last: its
/// account link, email limit and owner role were set up again on a facility
/// the owner already had.
FacilityModel? findJustCreatedFacility(
  List<FacilityModel> facilities, {
  required String name,
  required DateTime now,
}) {
  final wanted = name.trim();
  final since = now.subtract(facilityCreateRecoveryWindow);
  FacilityModel? newest;
  for (final f in facilities) {
    if (f.currentUserOwnsFacility != true) continue;
    if (f.name.trim() != wanted) continue;
    if (f.createdAt.isBefore(since)) continue;
    if (newest == null || f.createdAt.isAfter(newest.createdAt)) newest = f;
  }
  return newest;
}

/// Runs [create] and returns the new facility's id.
///
/// When [create] throws (a timeout, a dropped connection) the write may
/// still have gone through. [reloadFacilities] then reads the user's
/// facilities again (from the server, not the cache) and a facility found by
/// [findJustCreatedFacility] is taken as the one created, so the owner is
/// not invited to make it twice. Otherwise the error is rethrown.
Future<String> createFacilityOrRecover({
  required String name,
  required Future<String> Function() create,
  required Future<List<FacilityModel>> Function() reloadFacilities,
  DateTime Function() now = DateTime.now,
}) async {
  try {
    return await create();
  } catch (_) {
    List<FacilityModel> facilities = const [];
    try {
      facilities = await reloadFacilities();
    } catch (_) {
      // Could not check; report the create's own error below.
    }
    final made = findJustCreatedFacility(facilities, name: name, now: now());
    if (made != null) return made.id;
    rethrow;
  }
}
