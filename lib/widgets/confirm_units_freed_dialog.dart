import 'package:flutter/material.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Asked once the permanent delete check has passed and the delete would
/// free units the tenants still hold: names each unit, and true goes ahead.
/// Shared by the Tenants list and the tenant page.
Future<bool> confirmUnitsFreedDialog(
  BuildContext context,
  List<TenantDeletePlan> freeing,
) async {
  if (!context.mounted) return false;
  final count = freeing.fold<int>(0, (n, p) => n + p.heldUnits.length);
  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(count == 1 ? 'Free this unit?' : 'Free these $count units?'),
      content: SingleChildScrollView(
        child: Text(TenantService.unitsFreedMessage(freeing)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            count == 1 ? 'Delete and free unit' : 'Delete and free units',
            style: const TextStyle(color: AppTheme.error),
          ),
        ),
      ],
    ),
  );
  return go == true;
}
