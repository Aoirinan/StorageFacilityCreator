/// Validation for the contact details captured on a tenant.
///
/// A tenant's email is optional. Small operators sign people up at the gate
/// with a phone number and nothing else, and when the form demanded an address
/// they typed one in to get past it — which quietly points that tenant's
/// receipts and reminders at a stranger's mailbox. The phone number stays
/// required, because it is the one channel every tenant actually has.
library;

/// Matches the addresses people really type, including the longer top-level
/// domains (`.storage`, `.online`) that the old four-character limit rejected.
final RegExp _emailPattern = RegExp(
  r'^[\w.!#$%&’*+/=?^`{|}~-]+@[\w-]+(\.[\w-]+)+$',
);

/// Returns an error message when [value] is a non-empty, malformed address.
///
/// Blank is valid: it means the operator does not have an email for this
/// tenant. Use this for tenant forms, not for staff or account sign-in, where
/// an address is genuinely required.
String? validateOptionalTenantEmail(String? value) {
  final email = value?.trim() ?? '';
  if (email.isEmpty) {
    return null;
  }
  if (!_emailPattern.hasMatch(email)) {
    return 'Please enter a valid email address, or leave it blank';
  }
  return null;
}

/// Whether [email] can actually be sent to.
///
/// Every send path should ask this before queueing a message, so a tenant with
/// no address is skipped rather than failing at the provider.
bool isSendableTenantEmail(String? email) {
  final trimmed = email?.trim() ?? '';
  return trimmed.isNotEmpty && _emailPattern.hasMatch(trimmed);
}
