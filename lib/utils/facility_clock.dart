import 'package:sfcapp/utils/facility_clock_stub.dart'
    if (dart.library.js_interop) 'package:sfcapp/utils/facility_clock_web.dart' as platform;
import 'package:sfcapp/utils/local_date.dart';

/// Thrown when a facility time is asked for in a zone that is missing,
/// invalid, or not supported on this platform. Stays never falls back to the
/// browser's zone or to a default one (spec §0 "Time zone", §7.14).
class FacilityTimeZoneException implements Exception {
  const FacilityTimeZoneException(this.timeZone);

  final String? timeZone;

  @override
  String toString() => 'FacilityTimeZoneException: no usable time zone "$timeZone"';
}

/// "Now" at the facility: today's date, the local time and instants shown in
/// the facility's zone. Injected through facilityClockProvider so tests can
/// fix it; nothing in Stays uses DateTime.now() for a facility date.
abstract class FacilityClock {
  /// Today's date at the facility, 'YYYY-MM-DD'.
  String todayYmd(String timeZone);

  /// Today at the facility.
  LocalDate today(String timeZone) => LocalDate.parse(todayYmd(timeZone));

  /// The facility-local time now, 'HH:mm'.
  String nowLocalHm(String timeZone);

  /// [instant] at the facility, 'YYYY-MM-DD HH:mm'.
  String formatInstant(DateTime instant, String timeZone);

  /// Whether [timeZone] can be used on this platform.
  bool isValidZone(String? timeZone);

  /// The current instant (UTC); only for durations like "synced 6 min ago".
  DateTime nowUtc();
}

/// Builds 'YYYY-MM-DD HH:mm' from Intl.DateTimeFormat parts (year, month,
/// day, hour, minute). Some engines print midnight as hour 24.
String? localDateTimeFromParts(Map<String, String>? parts) {
  if (parts == null) return null;
  final year = int.tryParse(parts['year'] ?? '');
  final month = int.tryParse(parts['month'] ?? '');
  final day = int.tryParse(parts['day'] ?? '');
  final hour = int.tryParse(parts['hour'] ?? '');
  final minute = int.tryParse(parts['minute'] ?? '');
  if (year == null || month == null || day == null || hour == null || minute == null) return null;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${year.toString().padLeft(4, '0')}-${two(month)}-${two(day)} ${two(hour % 24)}:${two(minute)}';
}

/// The production clock: Intl in the browser (facility_clock_web.dart). On
/// other platforms only UTC is supported, and any other zone throws rather
/// than guessing.
class IntlFacilityClock extends FacilityClock {
  IntlFacilityClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  String _local(DateTime instant, String timeZone) {
    final value = localDateTimeFromParts(platform.wallClockParts(instant.toUtc(), timeZone));
    if (value == null) throw FacilityTimeZoneException(timeZone);
    return value;
  }

  @override
  String todayYmd(String timeZone) => _local(_now(), timeZone).substring(0, 10);

  @override
  String nowLocalHm(String timeZone) => _local(_now(), timeZone).substring(11);

  @override
  String formatInstant(DateTime instant, String timeZone) => _local(instant, timeZone);

  @override
  bool isValidZone(String? timeZone) =>
      timeZone != null && timeZone.isNotEmpty && platform.wallClockParts(DateTime.utc(2026), timeZone) != null;

  @override
  DateTime nowUtc() => _now().toUtc();
}

/// A clock for tests and previews: a fixed facility date and time, whatever
/// zone is asked for. [utcOffset] turns instants into facility-local times.
class FixedFacilityClock extends FacilityClock {
  FixedFacilityClock({
    required this.todayValue,
    this.nowHm = '12:00',
    this.utcOffset = Duration.zero,
    DateTime? nowUtcValue,
  }) : _nowUtc = nowUtcValue ?? DateTime.utc(2026);

  final LocalDate todayValue;
  final String nowHm;
  final Duration utcOffset;
  final DateTime _nowUtc;

  @override
  String todayYmd(String timeZone) => todayValue.toYmd();

  @override
  String nowLocalHm(String timeZone) => nowHm;

  @override
  String formatInstant(DateTime instant, String timeZone) {
    final local = instant.toUtc().add(utcOffset);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  @override
  bool isValidZone(String? timeZone) => timeZone != null && timeZone.isNotEmpty;

  @override
  DateTime nowUtc() => _nowUtc;
}
