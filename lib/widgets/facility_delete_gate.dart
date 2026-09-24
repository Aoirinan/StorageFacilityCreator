import 'package:flutter/material.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/facility_service.dart';

/// The owner's Delete, refused up front while [facility] has active
/// tenants (deleteFacilityPermanently refuses them too), before the typed
/// confirmation and the email code rather than after. False: stop. A check
/// that fails lets the delete go on, since the server checks again.
/// [blocker] is for tests.
Future<bool> facilityDeleteAllowed(
  BuildContext context,
  FacilityModel facility, {
  Future<String?> Function(String facilityId) blocker =
      FacilityService.facilityDeleteBlocker,
}) async {
  final String? reason;
  try {
    reason = await blocker(facility.id);
  } catch (_) {
    return true;
  }
  if (reason == null) return true;
  if (!context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text("Can't delete ${facility.name} yet"),
      content: Text(reason!),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return false;
}
