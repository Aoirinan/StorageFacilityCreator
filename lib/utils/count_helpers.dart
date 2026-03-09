/// Pure helpers for facility/unit counts. No Firestore or app dependencies.

/// Effective total units: use facility capacity when set (>0), else unit count (backward compat).
int effectiveTotalUnits(int facilityTotalUnits, int unitCount) {
  return facilityTotalUnits > 0 ? facilityTotalUnits : unitCount;
}
