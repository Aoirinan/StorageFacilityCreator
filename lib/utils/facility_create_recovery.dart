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

/// Added to the error when the create timed out and is still running:
/// Create stays off until it finishes.
const facilityCreateStillRunningHint =
    'It is still trying: Create comes back once it finishes.';

/// A facility create the wizard started, kept after it stops waiting.
///
/// A timeout does not cancel the create: offline, Firestore queues the
/// write and sends it on reconnect, and the account and subscription steps
/// before it may still be running. The wizard stopped waiting and turned
/// Create back on, and a second Create started a second create, so both
/// facilities were made, the late one without the wizard's account link,
/// owner role or subscription step. Now the wizard keeps Create off while
/// this runs, and the next Create takes the id it finished with instead of
/// creating again.
class FacilityCreateInFlight {
  FacilityCreateInFlight({this.onSettled});

  /// Called when a create started here finishes, whether or not anyone is
  /// still waiting for it: with its id, or with its error.
  final void Function(String? id, Object? error)? onSettled;

  Future<String>? _create;
  String? _name;
  bool _running = false;
  String? _createdId;

  /// Whether a create started here has not finished.
  bool get isRunning => _running;

  /// The id a create started here finished with; null while it runs, or
  /// when it failed.
  String? get createdId => _createdId;

  /// The name the kept create was started with.
  String? get name => _name;

  /// The create already started here that has not failed, running or
  /// finished; otherwise a new one from [start] for [name]. A failed create
  /// is dropped, so the next Create starts afresh.
  Future<String> join({
    required String name,
    required Future<String> Function() start,
  }) {
    final kept = _create;
    if (kept != null) return kept;
    _name = name;
    _running = true;
    // Future.sync: a create that throws before its first await still
    // settles here, rather than leaving Create off for good.
    final created = Future.sync(start);
    _create = created;
    created.then(
      (id) {
        _running = false;
        _createdId = id;
        onSettled?.call(id, null);
      },
      onError: (Object error) {
        _running = false;
        if (identical(_create, created)) {
          _create = null;
          _name = null;
        }
        onSettled?.call(null, error);
      },
    );
    return created;
  }
}

/// Runs [create], stopping after [timeout], and returns the new facility's
/// id.
///
/// With [inFlight], a create it already holds (still running, or finished
/// after an earlier attempt stopped waiting) is waited for or taken instead
/// of calling [create] again.
///
/// When the create times out or loses the network
/// ([facilityCreateMayHaveLanded]) the write may still have gone through.
/// [reloadFacilities] then reads the user's facilities again (from the
/// server, not the cache) and a facility found by [findJustCreatedFacility]
/// is taken as the one created, so the owner is not invited to make it
/// twice. Otherwise, and always for a refusal, the error is rethrown.
Future<String> createFacilityOrRecover({
  required String name,
  required Future<String> Function() create,
  required Future<List<FacilityModel>> Function() reloadFacilities,
  FacilityCreateInFlight? inFlight,
  DateTime Function() now = DateTime.now,
  Duration timeout = facilityCreateTimeout,
}) async {
  final attempt =
      inFlight == null ? create() : inFlight.join(name: name, start: create);
  // A kept create looks for the name it was started with.
  final createdAs = inFlight?.name ?? name;
  try {
    return await attempt.timeout(timeout);
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
    final made =
        findJustCreatedFacility(facilities, name: createdAs, now: now());
    if (made != null) return made.id;
    rethrow;
  }
}
