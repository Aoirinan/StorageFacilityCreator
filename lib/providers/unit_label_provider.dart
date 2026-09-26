import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/utils/unit_label.dart';

/// Whether the facility names units with their area
/// (`unitNumbersRepeatAcrossAreas`, see [unitLabelsIncludeArea]), for screens
/// that show a tenant's unit without otherwise loading the facility.
///
/// A facility that cannot be read counts as off, the label every facility
/// had before the setting: never an error the screen has to handle, and
/// nothing for Riverpod to retry.
final unitLabelsIncludeAreaProvider =
    FutureProvider.family<bool, String>((ref, facilityId) async {
  if (facilityId.isEmpty || facilityId == 'all') return false;
  try {
    return unitLabelsIncludeArea(await FacilityService.getFacility(facilityId));
  } catch (_) {
    return false;
  }
});

/// [unitLabelsIncludeAreaProvider] for [facilityId], for a tap handler that
/// fills a message: waits for the facility read the first time, then comes
/// from the cached value.
Future<bool> readUnitLabelsIncludeArea(WidgetRef ref, String facilityId) =>
    ref.read(unitLabelsIncludeAreaProvider(facilityId).future);
