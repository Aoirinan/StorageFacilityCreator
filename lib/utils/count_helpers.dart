/// Pure helpers for facility/unit counts. No Firestore or app dependencies.

/// Effective total units shown on dashboards = the count of unit documents
/// actually created in the unit list. The facility-level `totalUnits` value
/// (set in the wizard) is the **user-configured capacity max** and is kept
/// only as an editable cap; it is not what we display as "Total Units" on the
/// dashboard. Callers retain the capacity argument for parity, but it is
/// intentionally ignored here.
int effectiveTotalUnits(int facilityTotalUnits, int unitCount) {
  return unitCount;
}
