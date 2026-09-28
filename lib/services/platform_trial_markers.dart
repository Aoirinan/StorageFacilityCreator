/// Account fields for the super-admin "revoke trial" action.
///
/// Revoking clears `subscriptionTrialEnd`, which was the only record of the trial
/// for accounts granted one before `platformTrialUsedAt` existed. Checkout reads
/// that marker (functions-shared `platformCheckoutTrial.ts`) so an owner never gets
/// a second trial; without it a revoked trial would reopen a fresh 30-day one.
/// The marker is only written when missing, so the first-use time is kept.
///
/// [stamp] is the value to write for the marker and `updatedAt`
/// (`FieldValue.serverTimestamp()` in production).
Map<String, dynamic> revokeTrialFields(
  Map<String, dynamic>? current, {
  required Object stamp,
}) {
  final fields = <String, dynamic>{
    'subscriptionStatus': 'cancelled',
    'subscriptionTrialEnd': null,
    'subscriptionCurrentPeriodEnd': null,
    'updatedAt': stamp,
  };
  if (current?['platformTrialUsedAt'] == null) {
    fields['platformTrialUsedAt'] = stamp;
  }
  return fields;
}
