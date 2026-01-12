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
    // Default end date is last day of move-in month
    final effectiveEndDate = endDate ?? DateTime(moveInDate.year, moveInDate.month + 1, 0);
    
    // Calculate days in the month
    final daysInMonth = DateTime(moveInDate.year, moveInDate.month + 1, 0).day;
    
    // Calculate days remaining (including move-in day)
    final daysRemaining = effectiveEndDate.difference(moveInDate).inDays + 1;
    
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
    
    return proratedAmount;
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

