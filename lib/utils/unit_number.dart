/// A unit number as lookups compare it: trimmed, ignoring case. The public
/// map (FacilityMapV2Service) and the Area filter already matched tenants to
/// units this way; linking a tenant to a unit and the unit-number duplicate
/// checks compared the stored text exactly, so "12a" and "12A" were two
/// units to one and the same unit to the other.
String unitNumberKey(String unitNumber) => unitNumber.trim().toLowerCase();

/// Whether [a] and [b] name the same unit number under [unitNumberKey].
bool sameUnitNumber(String a, String b) => unitNumberKey(a) == unitNumberKey(b);
