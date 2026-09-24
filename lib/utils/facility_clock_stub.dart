/// Non-web builds and VM tests: there is no IANA zone database to consult,
/// so only UTC is answered. Any other zone returns null and the clock throws
/// FacilityTimeZoneException, rather than silently using the machine's zone.
/// Tests inject FixedFacilityClock instead.
Map<String, String>? wallClockParts(DateTime instantUtc, String timeZone) {
  if (timeZone != 'UTC' && timeZone != 'Etc/UTC') return null;
  final u = instantUtc.toUtc();
  return {
    'year': '${u.year}',
    'month': '${u.month}',
    'day': '${u.day}',
    'hour': '${u.hour}',
    'minute': '${u.minute}',
  };
}

/// Only UTC is known here, under either of its names.
String? canonicalZone(String timeZone) => timeZone == 'UTC' || timeZone == 'Etc/UTC' ? 'UTC' : null;
