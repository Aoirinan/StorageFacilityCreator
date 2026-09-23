import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/services/facility_stats_service.dart';

/// Whether the owner has added any units and any active tenants yet.
typedef OnboardingProgress = ({bool hasUnits, bool hasTenants});

/// [OnboardingProgress] across [facilityIds], from one yes-or-no probe per
/// facility for each question.
Future<OnboardingProgress> onboardingProgress(
  Iterable<String> facilityIds, {
  required Future<bool> Function(String facilityId) hasUnit,
  required Future<bool> Function(String facilityId) hasActiveTenant,
}) async {
  final ids = facilityIds.toList();
  final results = await Future.wait([
    Future.wait(ids.map(hasUnit)),
    Future.wait(ids.map(hasActiveTenant)),
  ]);
  return (
    hasUnits: results[0].any((found) => found),
    hasTenants: results[1].any((found) => found),
  );
}

/// The Settings onboarding checklist, keyed by the signed-in uid.
///
/// The checklist used to watch the dashboard provider for two yes-or-no
/// answers. Since the dashboard reloads on every visit, each visit to the
/// Settings tab ran the whole dashboard load: every tenant and unit, leads,
/// overdue queries and ledger sums, per facility. This reads at most two
/// documents per facility.
final onboardingProgressProvider =
    FutureProvider.autoDispose.family<OnboardingProgress, String>(
  (ref, userId) async {
    final facilities = await ref.watch(userFacilitiesProvider(userId).future);
    return onboardingProgress(
      facilities.map((f) => f.id),
      hasUnit: FacilityStatsService.facilityHasAnyUnitDoc,
      hasActiveTenant: FacilityStatsService.facilityHasAnyActiveTenant,
    );
  },
);
