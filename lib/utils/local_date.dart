import 'package:flutter/foundation.dart';

/// A calendar date with no time and no zone: one night of a stay, written
/// 'YYYY-MM-DD' in the facility's confirmed zone (Stays spec §3.1, §7.14).
///
/// Nights come from the server as strings and stay dates; they are never
/// turned into a DateTime in the browser's zone, which would shift them by a
/// day for anyone not sitting in the facility's zone.
@immutable
class LocalDate implements Comparable<LocalDate> {
  const LocalDate._(this.year, this.month, this.day);

  /// Throws [ArgumentError] for a date that does not exist (e.g. Feb 30).
  factory LocalDate(int year, int month, int day) {
    final utc = DateTime.utc(year, month, day);
    if (utc.year != year || utc.month != month || utc.day != day || year < 1900 || year > 2999) {
      throw ArgumentError('Not a calendar date: $year-$month-$day');
    }
    return LocalDate._(year, month, day);
  }

  final int year;
  final int month;
  final int day;

  static final RegExp _ymd = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
  static final RegExp _monthKey = RegExp(r'^(\d{4})-(\d{2})$');

  /// Parses 'YYYY-MM-DD' strictly; throws [FormatException] otherwise.
  static LocalDate parse(String value) {
    final parsed = tryParse(value);
    if (parsed == null) throw FormatException('Not a YYYY-MM-DD date', value);
    return parsed;
  }

  static LocalDate? tryParse(String? value) {
    if (value == null) return null;
    final m = _ymd.firstMatch(value);
    if (m == null) return null;
    try {
      return LocalDate(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    } on ArgumentError {
      return null;
    }
  }

  static bool isValidYmd(String? value) => tryParse(value) != null;

  /// 'YYYY-MM' → the first of that month.
  static LocalDate? tryParseMonth(String? monthKey) {
    if (monthKey == null || !_monthKey.hasMatch(monthKey)) return null;
    return tryParse('$monthKey-01');
  }

  DateTime get _utc => DateTime.utc(year, month, day);

  String toYmd() =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  /// 'YYYY-MM'.
  String get monthKey => toYmd().substring(0, 7);

  LocalDate addDays(int days) {
    final d = DateTime.utc(year, month, day + days);
    return LocalDate._(d.year, d.month, d.day);
  }

  /// Days from this date to [other] (negative when [other] is earlier).
  int daysUntil(LocalDate other) => other._utc.difference(_utc).inDays;

  /// ISO weekday: 1 = Monday … 7 = Sunday.
  int get weekday => _utc.weekday;

  bool get isFridayOrSaturday => weekday == DateTime.friday || weekday == DateTime.saturday;

  LocalDate get firstOfMonth => LocalDate._(year, month, 1);

  LocalDate get firstOfNextMonth {
    final d = DateTime.utc(year, month + 1, 1);
    return LocalDate._(d.year, d.month, d.day);
  }

  bool isBefore(LocalDate other) => compareTo(other) < 0;

  bool isAfter(LocalDate other) => compareTo(other) > 0;

  /// The nights of a stay: [checkIn] up to, but not including, [checkOut].
  static List<LocalDate> nights(LocalDate checkIn, LocalDate checkOut) {
    final count = checkIn.daysUntil(checkOut);
    return [for (var i = 0; i < count; i++) checkIn.addDays(i)];
  }

  /// Month keys holding any of the nights [from, toExclusive).
  static List<String> monthsSpanned(LocalDate from, LocalDate toExclusive) {
    if (!from.isBefore(toExclusive)) return const [];
    final last = toExclusive.addDays(-1).monthKey;
    final months = <String>[];
    for (var m = from.firstOfMonth; m.monthKey.compareTo(last) <= 0; m = m.firstOfNextMonth) {
      months.add(m.monthKey);
    }
    return months;
  }

  @override
  int compareTo(LocalDate other) => toYmd().compareTo(other.toYmd());

  @override
  bool operator ==(Object other) =>
      other is LocalDate && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => toYmd();
}
