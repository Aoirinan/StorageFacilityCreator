import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:state_notifier/state_notifier.dart';
import '../services/active_facility_service.dart';

/// Where the saved selection is read from and written to. A seam so tests
/// can drive [activeFacilityIdProvider] itself; production uses
/// [ActiveFacilityService].
final activeFacilityStoreProvider = Provider<
    ({
      Future<String?> Function() load,
      Future<void> Function(String? facilityId) save,
    })>(
  (ref) => (
    load: ActiveFacilityService.getActiveFacilityId,
    save: ActiveFacilityService.setActiveFacilityId,
  ),
);

/// Provider for the active facility ID
/// null means "All Facilities" is selected
///
/// Rebuilt whenever the signed-in account changes. It used to be built once
/// per app session, so after signing out and in as another account on the
/// same browser the previous account's facility stayed selected.
final activeFacilityIdProvider = StateNotifierProvider<ActiveFacilityNotifier, AsyncValue<String?>>((ref) {
  final auth = ref.watch(authStateProvider.select(
    (a) => (pending: a.isLoading && !a.hasValue, uid: a.value?.uid),
  ));
  // Auth not reported yet: wait, rather than read a selection for an
  // account that is not known.
  if (auth.pending) return ActiveFacilityNotifier.idle(const AsyncValue.loading());
  // Signed out: no account, so no selection.
  if (auth.uid == null) return ActiveFacilityNotifier.idle(const AsyncValue.data(null));
  final store = ref.watch(activeFacilityStoreProvider);
  return ActiveFacilityNotifier(load: store.load, save: store.save);
});

class ActiveFacilityNotifier extends StateNotifier<AsyncValue<String?>> {
  /// [load] and [save] default to [ActiveFacilityService]; tests pass fakes.
  ActiveFacilityNotifier({
    Future<String?> Function()? load,
    Future<void> Function(String? facilityId)? save,
  })  : _load = load ?? ActiveFacilityService.getActiveFacilityId,
        _save = save ?? ActiveFacilityService.setActiveFacilityId,
        super(const AsyncValue.loading()) {
    _loadActiveFacility();
  }

  /// Holds [state] without reading a saved selection: before auth has
  /// reported, or when no one is signed in.
  ActiveFacilityNotifier.idle(super.initial)
      : _load = _noSelection,
        _save = _discard;

  static Future<String?> _noSelection() async => null;
  static Future<void> _discard(String? _) async {}

  final Future<String?> Function() _load;
  final Future<void> Function(String? facilityId) _save;

  /// Bumped by [setActiveFacilityId]. A load that started before a choice
  /// was made must not overwrite it with the older saved value.
  int _choiceGeneration = 0;

  Future<void> _loadActiveFacility() async {
    final generation = _choiceGeneration;
    AsyncValue<String?> next;
    try {
      next = AsyncValue.data(await _load());
    } catch (e, stackTrace) {
      next = AsyncValue.error(e, stackTrace);
    }
    // Both checks guard a late read: the notifier is replaced when the
    // account changes, and a facility picked while the saved value was
    // still loading (e.g. the single-facility auto-select on first sign-in)
    // used to be overwritten by it.
    if (!mounted || generation != _choiceGeneration) return;
    state = next;
  }

  /// Set the active facility ID
  /// Pass null to select "All Facilities"
  Future<void> setActiveFacilityId(String? facilityId) async {
    _choiceGeneration++;
    // Publish the choice before the remote write. Going through loading first
    // held every facility switch on a users-doc round trip, and anything
    // watching read the loading state as "All Facilities" meanwhile (the
    // dashboard ran a full all-facilities load it then threw away).
    if (!(state is AsyncData<String?> && state.value == facilityId)) {
      state = AsyncValue.data(facilityId);
    }
    try {
      await _save(facilityId);
    } catch (e) {
      // The service updates its cache and local storage before the users
      // doc, so the choice holds on this device; only the copy that follows
      // the user to other devices failed.
      if (kDebugMode) {
        print('⚠️ [ActiveFacility] Could not save active facility remotely: $e');
      }
    }
  }

  /// Refresh the active facility from storage
  Future<void> refresh() async {
    await _loadActiveFacility();
  }
}
