/// Models for various report types

class ARAgingBucket {
  final String range; // e.g., "0-30", "31-60", "61-90", "90+"
  final double amount;
  final int tenantCount;

  const ARAgingBucket({
    required this.range,
    required this.amount,
    required this.tenantCount,
  });
}

class ARAgingReport {
  final List<ARAgingBucket> buckets;
  final double totalAR;
  final int totalTenants;

  const ARAgingReport({
    required this.buckets,
    required this.totalAR,
    required this.totalTenants,
  });
}

class OccupancyMetrics {
  final int totalUnits;
  final int occupiedUnits;
  final int availableUnits;
  final int reservedUnits;
  final int maintenanceUnits;
  final double occupancyRate; // Percentage
  final double averageMonthlyRate;
  final double potentialMonthlyRevenue;
  final double actualMonthlyRevenue;

  const OccupancyMetrics({
    required this.totalUnits,
    required this.occupiedUnits,
    required this.availableUnits,
    required this.reservedUnits,
    required this.maintenanceUnits,
    required this.occupancyRate,
    required this.averageMonthlyRate,
    required this.potentialMonthlyRevenue,
    required this.actualMonthlyRevenue,
  });
}

class DelinquencySummary {
  final int currentCount;
  final int lateCount; // 1-7 days
  final int overdueCount; // 8-30 days
  final int severelyOverdueCount; // 30+ days
  final double currentAmount;
  final double lateAmount;
  final double overdueAmount;
  final double severelyOverdueAmount;
  final double totalDelinquentAmount;

  const DelinquencySummary({
    required this.currentCount,
    required this.lateCount,
    required this.overdueCount,
    required this.severelyOverdueCount,
    required this.currentAmount,
    required this.lateAmount,
    required this.overdueAmount,
    required this.severelyOverdueAmount,
    required this.totalDelinquentAmount,
  });
}

class DepositSummary {
  final int totalDeposits;
  final int pendingDeposits;
  final int depositedCount;
  final int reconciledCount;
  final double totalAmount;
  final double pendingAmount;
  final double depositedAmount;
  final double reconciledAmount;
  final double totalOverShort;

  const DepositSummary({
    required this.totalDeposits,
    required this.pendingDeposits,
    required this.depositedCount,
    required this.reconciledCount,
    required this.totalAmount,
    required this.pendingAmount,
    required this.depositedAmount,
    required this.reconciledAmount,
    required this.totalOverShort,
  });
}

