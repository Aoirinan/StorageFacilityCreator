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
  static double calculateProratedRent({
    required double monthlyRate,
    required DateTime moveInDate,
    DateTime? endDate,
  }) {
    // Compare calendar days, not instants.
    //
    // `difference(...).inDays` truncates, so a move-in stamped 15 Jan 14:30
    // against a 31 Jan midnight end date measured 15 days rather than 16,
    // billing one day short: on $200 that is $103.23 charged where $109.68 was
    // owed. Normalising both endpoints to midnight removes the dependence on
    // what time of day the record happened to be created.
    final startDay = DateTime(moveInDate.year, moveInDate.month, moveInDate.day);
    final lastDayOfMonth = DateTime(moveInDate.year, moveInDate.month + 1, 0);
    final rawEnd = endDate ?? lastDayOfMonth;
    final endDay = DateTime(rawEnd.year, rawEnd.month, rawEnd.day);

    // Calculate days in the month
    final daysInMonth = lastDayOfMonth.day;

    // Calculate days remaining (including move-in day)
    final daysRemaining = endDay.difference(startDay).inDays + 1;
    
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
    return endDate.difference(startDate).inDays + 1; // +1 to include both start and end days
  }

  /// Calculate number of days remaining in month from a date
  static int calculateDaysRemainingInMonth(DateTime date) {
    final lastDayOfMonth = DateTime(date.year, date.month + 1, 0);
    return lastDayOfMonth.difference(date).inDays + 1; // +1 to include the date itself
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

