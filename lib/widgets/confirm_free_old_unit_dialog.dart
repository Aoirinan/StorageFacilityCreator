import 'package:flutter/material.dart';

/// Edit Tenant, after picking a different unit for a tenant who still holds
/// unit [oldUnitNumber]: true frees it, false keeps both. Picking a unit
/// used to add it silently, leaving the old one occupied and unrentable.
/// Dismissing counts as keeping both: nothing is freed unasked.
Future<bool> confirmFreeOldUnitDialog(
  BuildContext context, {
  required String tenantName,
  required String oldUnitNumber,
  required String newUnitNumber,
}) async {
  if (!context.mounted) return false;
  final free = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Also free unit $oldUnitNumber?'),
      content: Text(
        '$tenantName is getting unit $newUnitNumber and still holds unit '
        '$oldUnitNumber.\n\n'
        'Free unit $oldUnitNumber: it is unassigned, listed as available to '
        'rent, and its rent comes off theirs.\n'
        'Keep both: their monthly rent becomes the rent of both units.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Keep both'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Free unit $oldUnitNumber'),
        ),
      ],
    ),
  );
  return free == true;
}
