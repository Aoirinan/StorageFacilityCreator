import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:sfcapp/models/facility_model.dart';

/// Longest the wizard waits for a facility create. Offline, Firestore holds
/// the write until it reconnects, so the create never finished and Create
/// spun until the page was closed.
const facilityCreateTimeout = Duration(seconds: 30);

/// Firebase error codes after which the create's write may still have
/// landed: the connection, not a rule or a check, stopped it.
const _networkFailureCodes = {
  'unavailable',
  'deadline-exceeded',
  'network-request-failed',
};

/// Whether a create that threw [error] may have written the facility
/// anyway: it timed out or lost the network. Refusals (subscription
/// required, a unit count out of range, permission denied, not signed in)
/// are thrown before anything is written.
bool facilityCreateMayHaveLanded(Object error) {
  if (error is TimeoutException) return true;
  return error is FirebaseException && _networkFailureCodes.contains(error.code);
}

/// How recently a facility must have been created to count as the one an
/// attempt that reported an error made anyway.
const facilityCreateRecoveryWindow = Duration(minutes: 5);

/// Added to the error when a create timed out or lost the network and no
/// facility it made could be found: the write may still land (or have landed
/// where the re-check could not see it), and Create is live again. Not for
/// refusals, where nothing was written.
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

/// Runs [create], stopping after [timeout], and returns the new facility's
/// id.
///
/// When [create] times out or loses the network
/// ([facilityCreateMayHaveLanded]) the write may still have gone through.
/// [reloadFacilities] then reads the user's facilities again (from the
/// server, not the cache) and a facility found by [findJustCreatedFacility]
/// is taken as the one created, so the owner is not invited to make it
/// twice. Otherwise, and always for a refusal, the error is rethrown.
Future<String> createFacilityOrRecover({
  required String name,
  required Future<String> Function() create,
  required Future<List<FacilityModel>> Function() reloadFacilities,
  DateTime Function() now = DateTime.now,
  Duration timeout = facilityCreateTimeout,
}) async {
  try {
    return await create().timeout(timeout);
  } catch (e) {
    // A refusal wrote nothing. Looking anyway took a same-name facility
    // made minutes earlier as this one: a "subscription required" was
    // swallowed and the wizard set that facility up again and said
    // "created".
    if (!facilityCreateMayHaveLanded(e)) rethrow;
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
