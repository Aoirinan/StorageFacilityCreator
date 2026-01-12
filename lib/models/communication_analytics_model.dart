import 'package:cloud_firestore/cloud_firestore.dart';

/// Communication analytics for a facility
class CommunicationAnalytics {
  final String facilityId;
  final DateTime periodStart;
  final DateTime periodEnd;
  
  // Email metrics
  final int emailsSent;
  final int emailsDelivered;
  final int emailsOpened;
  final int emailsClicked;
  final int emailsBounced;
  final int emailsFailed;
  final double emailOpenRate;
  final double emailClickRate;
  final double emailDeliveryRate;
  
  // SMS metrics
  final int smsSent;
  final int smsDelivered;
  final int smsFailed;
  final double smsDeliveryRate;
  
  // Cost metrics
  final double emailCost;
  final double smsCost;
  final double totalCost;
  
  // Usage metrics
  final int emailLimit;
  final int smsLimit;
  final double emailUsagePercentage;
  final double smsUsagePercentage;

  const CommunicationAnalytics({
    required this.facilityId,
    required this.periodStart,
    required this.periodEnd,
    this.emailsSent = 0,
    this.emailsDelivered = 0,
    this.emailsOpened = 0,
    this.emailsClicked = 0,
    this.emailsBounced = 0,
    this.emailsFailed = 0,
    this.emailOpenRate = 0.0,
    this.emailClickRate = 0.0,
    this.emailDeliveryRate = 0.0,
    this.smsSent = 0,
    this.smsDelivered = 0,
    this.smsFailed = 0,
    this.smsDeliveryRate = 0.0,
    this.emailCost = 0.0,
    this.smsCost = 0.0,
    this.totalCost = 0.0,
    this.emailLimit = 0,
    this.smsLimit = 0,
    this.emailUsagePercentage = 0.0,
    this.smsUsagePercentage = 0.0,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'periodStart': Timestamp.fromDate(periodStart),
      'periodEnd': Timestamp.fromDate(periodEnd),
      'emailsSent': emailsSent,
      'emailsDelivered': emailsDelivered,
      'emailsOpened': emailsOpened,
      'emailsClicked': emailsClicked,
      'emailsBounced': emailsBounced,
      'emailsFailed': emailsFailed,
      'emailOpenRate': emailOpenRate,
      'emailClickRate': emailClickRate,
      'emailDeliveryRate': emailDeliveryRate,
      'smsSent': smsSent,
      'smsDelivered': smsDelivered,
      'smsFailed': smsFailed,
      'smsDeliveryRate': smsDeliveryRate,
      'emailCost': emailCost,
      'smsCost': smsCost,
      'totalCost': totalCost,
      'emailLimit': emailLimit,
      'smsLimit': smsLimit,
      'emailUsagePercentage': emailUsagePercentage,
      'smsUsagePercentage': smsUsagePercentage,
    };
  }

  factory CommunicationAnalytics.fromMap(Map<String, dynamic> map) {
    return CommunicationAnalytics(
      facilityId: map['facilityId'] as String,
      periodStart: (map['periodStart'] as Timestamp).toDate(),
      periodEnd: (map['periodEnd'] as Timestamp).toDate(),
      emailsSent: map['emailsSent'] as int? ?? 0,
      emailsDelivered: map['emailsDelivered'] as int? ?? 0,
      emailsOpened: map['emailsOpened'] as int? ?? 0,
      emailsClicked: map['emailsClicked'] as int? ?? 0,
      emailsBounced: map['emailsBounced'] as int? ?? 0,
      emailsFailed: map['emailsFailed'] as int? ?? 0,
      emailOpenRate: (map['emailOpenRate'] as num?)?.toDouble() ?? 0.0,
      emailClickRate: (map['emailClickRate'] as num?)?.toDouble() ?? 0.0,
      emailDeliveryRate: (map['emailDeliveryRate'] as num?)?.toDouble() ?? 0.0,
      smsSent: map['smsSent'] as int? ?? 0,
      smsDelivered: map['smsDelivered'] as int? ?? 0,
      smsFailed: map['smsFailed'] as int? ?? 0,
      smsDeliveryRate: (map['smsDeliveryRate'] as num?)?.toDouble() ?? 0.0,
      emailCost: (map['emailCost'] as num?)?.toDouble() ?? 0.0,
      smsCost: (map['smsCost'] as num?)?.toDouble() ?? 0.0,
      totalCost: (map['totalCost'] as num?)?.toDouble() ?? 0.0,
      emailLimit: map['emailLimit'] as int? ?? 0,
      smsLimit: map['smsLimit'] as int? ?? 0,
      emailUsagePercentage: (map['emailUsagePercentage'] as num?)?.toDouble() ?? 0.0,
      smsUsagePercentage: (map['smsUsagePercentage'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Cost breakdown by service
class CostBreakdown {
  final double emailCost;
  final double smsCost;
  final double totalCost;
  final int emailCount;
  final int smsCount;
  final double costPerEmail;
  final double costPerSMS;

  const CostBreakdown({
    this.emailCost = 0.0,
    this.smsCost = 0.0,
    this.totalCost = 0.0,
    this.emailCount = 0,
    this.smsCount = 0,
    this.costPerEmail = 0.0,
    this.costPerSMS = 0.0,
  });

  Map<String, dynamic> toMap() {
    return {
      'emailCost': emailCost,
      'smsCost': smsCost,
      'totalCost': totalCost,
      'emailCount': emailCount,
      'smsCount': smsCount,
      'costPerEmail': costPerEmail,
      'costPerSMS': costPerSMS,
    };
  }
}

