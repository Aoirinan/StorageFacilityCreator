/// Which billing model governs whether an owner may add another facility.
///
/// Legacy accounts carry one subscription on the account record, and the
/// account's trial or status decides how many facilities they may create.
/// Per-facility accounts (docs/PER_FACILITY_SUBSCRIPTION_DESIGN.md) subscribe
/// each facility separately right after it is created, so the account-level
/// fields are leftovers and must not block creation. The bug this replaces
/// told a per-facility owner "Your trial has expired" when adding a second
/// facility, because the account record's old trial had lapsed.
bool usesPerFacilityBilling(Iterable<String?> platformSubscriptionIds) {
  return platformSubscriptionIds.any((id) => (id ?? '').trim().isNotEmpty);
}
