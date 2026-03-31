import 'package:flutter/material.dart';
import '../services/email_service.dart';
import '../theme/app_theme.dart';

/// True when the failure is due to facility email suppression / unsubscribe.
bool recipientUnsubscribedEmailFailure(EmailResult result) {
  if (result.errorCode == 'recipient-unsubscribed') return true;
  return result.error?.toLowerCase().contains('unsubscribed') ?? false;
}

/// Snackbar when an outbound tenant email fails (staff-facing hints).
void showStaffEmailFailureSnackBar(BuildContext context, EmailResult result) {
  if (result.success) return;
  final msg = EmailService.staffEmailFailureHint(result);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      backgroundColor:
          recipientUnsubscribedEmailFailure(result) ? AppTheme.warning : AppTheme.error,
    ),
  );
}
