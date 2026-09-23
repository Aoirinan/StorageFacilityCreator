import 'package:flutter/material.dart';

import 'package:sfcapp/models/dnr_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/back_navigation.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Shows the DNR alert over a tenant's page. "Override & Continue" calls
/// [onOverride] and keeps the page open; Cancel closes the alert and then
/// leaves the tenant's page.
///
/// [context] must be the tenant page's own context. Cancel used to pop twice
/// from the dialog's context. The dialog sits on the root navigator, so the
/// second pop removed the whole app shell instead of the tenant page and left
/// a blank screen.
Future<void> showDnrBlockingDialog(
  BuildContext context, {
  required List<DNRModel> matches,
  required VoidCallback onOverride,
}) async {
  final overridden = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: AppTheme.error),
            const SizedBox(width: 8),
            const Text('DNR Alert'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This tenant matches ${matches.length} active DNR entr${matches.length == 1 ? 'y' : 'ies'}:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...matches.map((match) => Card(
              color: AppTheme.error.withOpacity(0.1),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Name: ${match.name}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (match.email.isNotEmpty)
                      Text('Email: ${match.email}'),
                    if (match.phone.isNotEmpty)
                      Text('Phone: ${match.phone}'),
                    Text('Reason: ${match.reason}'),
                    if (match.addedByName != null && match.addedByEmail != null)
                      Text(
                        'Added by: ${match.addedByName} (${match.addedByEmail})',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    if (match.facilityName != null)
                      Text(
                        'Facility: ${match.facilityName}',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    if (match.expiresAt != null)
                      Text('Expires: ${match.expiresAt!.toLocal().toString().split(' ')[0]}'),
                  ],
                ),
              ),
            )),
            const SizedBox(height: 16),
            const Text(
              'Do you want to override and continue?',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            // Only close the alert; leaving the page happens below, from the
            // page's own context.
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              onOverride();
              Navigator.of(dialogContext).pop(true); // Close dialog
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Override & Continue'),
          ),
        ],
      );
    },
  );

  // Cancel means "don't open this tenant": back to where they came from, or
  // the tenant list when the page was opened directly.
  if (overridden == true || !context.mounted) return;
  popOrGo(context, AppRoute.tenants);
}
