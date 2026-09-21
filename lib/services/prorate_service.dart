import 'package:flutter/foundation.dart';

/// Service for calculating prorated amounts
class ProrateService {
  /// Calculate prorated rent for a partial month
  /// 
  /// Formula: (Monthly Rate / Days in Month) * Days Remaining
  /// 
  /// Example:
  /// - Move-in date: Jan 15
  /// - Monthly rate: $100
  /// - Days in January: 31
  /// - Days remaining: 17 (Jan 15-31)
  /// - Prorated: (100 / 31) * 17 = $54.84
  /// Whole calendar days from [start] to [end], counting both ends.
  ///
  /// Both endpoints are rebuilt as UTC midnights before subtracting. Two
  /// separate faults are avoided that way:
  ///
  /// 1. `difference(...).inDays` truncates, so a move-in stamped 15 Jan 14:30
  ///    against a 31 Jan midnight end date measured 15 days rather than 16,
  ///    billing one day short: on $200 that is $103.23 charged where $109.68
  ///    was owed.
  /// 2. Local time is not a uniform scale. Across the spring daylight-saving
  ///    transition a month is 24 hours short of a whole number of days, so
  ///    1 Mar to 31 Mar measured 29 days rather than 30 and a tenant renting
  ///    the whole of March was billed 30/31 of the rent. UTC has no such
  ///    transition, and calendar dates carry no timezone meaning here anyway.
  static int _calendarDaysInclusive(DateTime start, DateTime end) {
    final startDay = DateTime.utc(start.year, start.month, start.day);
    final endDay = DateTime.utc(end.year, end.month, end.day);
    return endDay.difference(startDay).inDays + 1;
  }

  static double calculateProratedRent({
    required double monthlyRate,
    required DateTime moveInDate,
    DateTime? endDate,
  }) {
    final lastDayOfMonth = DateTime(moveInDate.year, moveInDate.month + 1, 0);
    final rawEnd = endDate ?? lastDayOfMonth;

    // Calculate days in the month
    final daysInMonth = lastDayOfMonth.day;

    // Days remaining, including the move-in day. An end date before the start
    // is a caller error rather than a credit, so it bills nothing instead of
    // posting a negative charge to the ledger.
    final daysRemaining =
        _calendarDaysInclusive(moveInDate, rawEnd).clamp(0, daysInMonth);

    // Calculate daily rate
    final dailyRate = monthlyRate / daysInMonth;
    
    // Calculate prorated amount
    final proratedAmount = dailyRate * daysRemaining;
    
    if (kDebugMode) {
      print('💰 [Prorate] Monthly Rate: \$${monthlyRate.toStringAsFixed(2)}');
      print('💰 [Prorate] Move-in Date: ${moveInDate.toIso8601String()}');
      print('💰 [Prorate] Days in Month: $daysInMonth');
      print('💰 [Prorate] Days Remaining: $daysRemaining');
      print('💰 [Prorate] Daily Rate: \$${dailyRate.toStringAsFixed(2)}');
      print('💰 [Prorate] Prorated Amount: \$${proratedAmount.toStringAsFixed(2)}');
    }
    
    // Rounded to cents. A raw float here reached the ledger and left residue
    // that never let a balance settle to exactly zero.
    return double.parse(proratedAmount.toStringAsFixed(2));
  }

  /// Calculate prorated amount for any charge
  /// 
  /// Useful for insurance, fees, etc. that are charged monthly
  static double calculateProratedCharge({
    required double monthlyAmount,
    required DateTime startDate,
    DateTime? endDate,
  }) {
    return calculateProratedRent(
      monthlyRate: monthlyAmount,
      moveInDate: startDate,
      endDate: endDate,
    );
  }

  /// Calculate number of days in a date range
  static int calculateDaysInRange({
    required DateTime startDate,
    required DateTime endDate,
  }) {
    return _calendarDaysInclusive(startDate, endDate);
  }

  /// Calculate number of days remaining in month from a date
  ///
  /// `move_in_service` puts this count in the ledger description beside the
  /// amount from [calculateProratedRent], so the two must be derived the same
  /// way. They were not: this one measured from the raw timestamp, so a
  /// move-in recorded at 14:30 was billed for 17 days and labelled "16 days".
  static int calculateDaysRemainingInMonth(DateTime date) {
    final lastDayOfMonth = DateTime(date.year, date.month + 1, 0);
    return _calendarDaysInclusive(date, lastDayOfMonth);
  }

  /// Get first day of next month
  static DateTime getFirstDayOfNextMonth(DateTime date) {
    if (date.month == 12) {
      return DateTime(date.year + 1, 1, 1);
    }
    return DateTime(date.year, date.month + 1, 1);
  }

  /// Get last day of month
  static DateTime getLastDayOfMonth(DateTime date) {
    return DateTime(date.year, date.month + 1, 0);
  }
}

