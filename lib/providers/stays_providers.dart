import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_channel_blocks.dart';
import 'package:sfcapp/models/stays/stay_controls.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stay_message_template.dart';
import 'package:sfcapp/models/stays/stay_night_lock_bucket.dart';
import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/services/stays/stays_callables.dart';
import 'package:sfcapp/services/stays/stays_repository.dart';
import 'package:sfcapp/services/stays/today_board.dart';
import 'package:sfcapp/utils/facility_clock.dart';
import 'package:sfcapp/utils/local_date.dart';

/// The feature flag that shows the Stays UI (appConfig/featureFlags).
const String staysFeatureFlagKey = 'shortTermRentals';

// --- Seams --------------------------------------------------------------------------

final staysRepositoryProvider = Provider<StaysRepository>((ref) => FirestoreStaysRepository());

final staysCallablesProvider = Provider<StaysCallables>((ref) => FirebaseStaysCallables());

/// "Now" at the facility. Tests override it with FixedFacilityClock.
final facilityClockProvider = Provider<FacilityClock>((ref) => IntlFacilityClock());

/// The signed-in user's uid.
final staysCurrentUidProvider = Provider<String?>((ref) => ref.watch(authStateProvider).value?.uid);

/// facilities/{id}.timeZone, for the mismatch warning only (never a fallback).
final staysFacilityTimeZoneProvider = Provider.family<String?, String>(
  (ref, facilityId) => ref.watch(facilityProvider(facilityId)).value?.timeZone,
);

// --- Gates (spec §7.1) ----------------------------------------------------------------

enum StaysUiState { loading, on, off }

/// Whether the shortTermRentals flag has loaded, and to what. Loading and
/// errors are never "on": featureFlagEnabledProvider reads every flag as on
/// until the doc arrives, which is why it is not used here.
final staysUiStateProvider = Provider<StaysUiState>((ref) {
  final flags = ref.watch(featureFlagsProvider);
  return switch (flags) {
    AsyncData(:final value) =>
      value.any((f) => f.key == staysFeatureFlagKey && f.enabled == true) ? StaysUiState.on : StaysUiState.off,
    AsyncError() => StaysUiState.off,
    _ => StaysUiState.loading,
  };
});

/// True only when the feature flags have loaded and shortTermRentals is
/// explicitly enabled. It only hides UI; the server gates are
/// staysServerConfig and stayControls.
final staysUiAllowedProvider = Provider<bool>((ref) => ref.watch(staysUiStateProvider) == StaysUiState.on);

/// stayControls/current; a missing doc reads as all defaults (module off).
final stayControlsProvider = StreamProvider.family<StayControls, String>(
  (ref, facilityId) => ref.watch(staysRepositoryProvider).watchControls(facilityId),
);

/// True only when the UI flag is on and stayControls/current.moduleEnabled is
/// true. A missing doc, loading or an error all mean false; with the flag off
/// nothing is even read.
final staysModuleEnabledProvider = Provider.family<bool, String>((ref, facilityId) {
  if (!ref.watch(staysUiAllowedProvider)) return false;
  final controls = ref.watch(stayControlsProvider(facilityId));
  return switch (controls) {
    AsyncData(:final value) => value.moduleEnabled == true,
    _ => false,
  };
});

/// Whether the platform lets this facility use Stays (staysGetAvailability),
/// asked once per session per facility and only when the UI flag is on. It
/// drives the setup prompt. A failed call reads as not available.
final staysAvailabilityProvider = FutureProvider.family<StaysAvailability, String>((ref, facilityId) async {
  if (!ref.watch(staysUiAllowedProvider)) return StaysAvailability.unavailable;
  // Any failure is "not available", never an error: an error would be retried
  // (Riverpod's automatic retry) and call the server again and again.
  try {
    return await ref.read(staysCallablesProvider).getAvailability(facilityId);
  } on StaysCallableException catch (e) {
    debugPrint('staysGetAvailability($facilityId): ${e.reason.wire}');
    return StaysAvailability.unavailable;
  } catch (e) {
    debugPrint('staysGetAvailability($facilityId): $e');
    return StaysAvailability.unavailable;
  }
});

/// How a permission at one facility is checked; tests replace it.
final stayPermissionResolverProvider = Provider<Future<bool> Function(String facilityId, PermissionType permission)>(
  (ref) => (facilityId, permission) async =>
      (await PermissionService.hasPermission(permission: permission, facilityId: facilityId)).hasPermission,
);

/// A permission at one explicit facility. Never PermissionGate's fallback to
/// the user's highest role across facilities; no facility means no.
final stayPermissionProvider = FutureProvider.family<bool, (String, PermissionType)>((ref, key) async {
  final (facilityId, permission) = key;
  if (facilityId.isEmpty || facilityId == 'all') return false;
  final resolve = ref.watch(stayPermissionResolverProvider);
  try {
    return await resolve(facilityId, permission);
  } catch (e) {
    debugPrint('stayPermission($facilityId, ${permission.name}): $e');
    return false;
  }
});

// --- Data ---------------------------------------------------------------------------------

/// A facility and a date window [from, to).
@immutable
class StayRangeKey {
  const StayRangeKey(this.facilityId, this.from, this.to);

  final String facilityId;
  final LocalDate from;
  final LocalDate to;

  @override
  bool operator ==(Object other) =>
      other is StayRangeKey && other.facilityId == facilityId && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(facilityId, from, to);
}

final stayListingsProvider = StreamProvider.family<List<StayListing>, String>(
  (ref, facilityId) => ref.watch(staysRepositoryProvider).watchListings(facilityId),
);

final staysInRangeProvider = StreamProvider.family<List<Stay>, StayRangeKey>(
  (ref, key) => ref.watch(staysRepositoryProvider).watchStaysInRange(key.facilityId, key.from, key.to),
);

final stayLockBucketsProvider = StreamProvider.family<List<StayNightLockBucket>, StayRangeKey>(
  (ref, key) => ref
      .watch(staysRepositoryProvider)
      .watchLockBuckets(key.facilityId, LocalDate.monthsSpanned(key.from, key.to)),
);

final stayChannelBlocksProvider = StreamProvider.family<List<StayChannelBlocks>, String>(
  (ref, facilityId) => ref.watch(staysRepositoryProvider).watchChannelBlocks(facilityId),
);

final stayTasksInRangeProvider = StreamProvider.family<List<StayTask>, StayRangeKey>(
  (ref, key) => ref.watch(staysRepositoryProvider).watchTasksInRange(key.facilityId, key.from, key.to),
);

/// Open tasks assigned to the signed-in user, due from [StayRangeKey.from].
final myStayTasksProvider = StreamProvider.family<List<StayTask>, StayRangeKey>((ref, key) {
  final uid = ref.watch(staysCurrentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(staysRepositoryProvider).watchMyTasks(key.facilityId, uid, key.from);
});

/// Channels and their sync health: owners and managers only. Anyone else
/// gets an empty list rather than a permission error.
final stayChannelsProvider = StreamProvider.family<List<StayChannel>, String>((ref, facilityId) async* {
  final repository = ref.watch(staysRepositoryProvider);
  final allowed = await ref.watch(stayPermissionProvider((facilityId, PermissionType.manageStayChannels)).future);
  if (!allowed) {
    yield const [];
    return;
  }
  yield* repository.watchChannels(facilityId);
});

final stayMessageTemplatesProvider = StreamProvider.family<List<StayMessageTemplate>, String>(
  (ref, facilityId) => ref.watch(staysRepositoryProvider).watchTemplates(facilityId),
);

/// The Today board for a facility, in its confirmed zone. Fails with
/// FacilityTimeZoneException until the zone is confirmed; it never guesses.
final staysTodayBoardProvider = Provider.autoDispose.family<AsyncValue<TodayBoard>, String>((ref, facilityId) {
  final controlsAsync = ref.watch(stayControlsProvider(facilityId));
  final controls = controlsAsync.value;
  if (controls == null) {
    return controlsAsync.hasError
        ? AsyncError(controlsAsync.error!, controlsAsync.stackTrace ?? StackTrace.current)
        : const AsyncLoading();
  }
  final tz = controls.confirmedTimeZone;
  final clock = ref.watch(facilityClockProvider);
  if (tz == null || !clock.isValidZone(tz)) {
    return AsyncError(FacilityTimeZoneException(controls.timeZone), StackTrace.current);
  }
  final LocalDate today;
  try {
    today = clock.today(tz);
  } on FacilityTimeZoneException catch (e, st) {
    return AsyncError(e, st);
  }

  // Overdue departures (checked in after their checkout day) need a look back.
  final staysAsync = ref.watch(staysInRangeProvider(StayRangeKey(facilityId, today.addDays(-30), today.addDays(91))));
  final listingsAsync = ref.watch(stayListingsProvider(facilityId));
  final tasksAsync = ref.watch(stayTasksInRangeProvider(StayRangeKey(facilityId, today.addDays(-7), today.addDays(2))));
  final channels = ref.watch(stayChannelsProvider(facilityId)).value ?? const <StayChannel>[];
  final showMoney = ref.watch(stayPermissionProvider((facilityId, PermissionType.manageStayMoney))).value ?? false;

  for (final part in <AsyncValue<Object>>[staysAsync, listingsAsync, tasksAsync]) {
    if (part.hasError) return AsyncError(part.error!, part.stackTrace ?? StackTrace.current);
  }
  final stays = staysAsync.value;
  final listings = listingsAsync.value;
  final tasks = tasksAsync.value;
  if (stays == null || listings == null || tasks == null) return const AsyncLoading();

  return AsyncData(buildTodayBoard(
    today: today,
    listings: listings,
    stays: stays,
    tasks: tasks,
    channels: channels,
    nowUtc: clock.nowUtc(),
    controlsTimeZone: tz,
    facilityTimeZone: ref.watch(staysFacilityTimeZoneProvider(facilityId)),
    showMoney: showMoney,
  ));
});
