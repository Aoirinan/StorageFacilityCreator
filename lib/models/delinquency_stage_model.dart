import 'package:cloud_firestore/cloud_firestore.dart';

enum DelinquencyStage {
  current, // No delinquency
  late, // 1-7 days late
  overdue, // 8-30 days late
  noticeSent, // Late notice sent
  finalNotice, // Final notice sent
  lienFiled, // Lien filed
  auctionScheduled, // Auction scheduled
  auctionComplete, // Auction completed
  resolved, // Delinquency resolved
}

class DelinquencyStageModel {
  final String id;
  final String facilityId;
  final String tenantId;
  final DelinquencyStage currentStage;
  final DateTime stageDate; // Date entered current stage
  final DateTime? noticeSentDate;
  final DateTime? finalNoticeSentDate;
  final DateTime? lienFiledDate;
  final DateTime? auctionScheduledDate;
  final DateTime? auctionCompleteDate;
  final DateTime? resolvedDate;
  final double totalBalance; // Total amount owed
  final double lateFees; // Total late fees
  final int daysOverdue;
  final String? notes;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isActive;

  const DelinquencyStageModel({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.currentStage,
    required this.stageDate,
    this.noticeSentDate,
    this.finalNoticeSentDate,
    this.lienFiledDate,
    this.auctionScheduledDate,
    this.auctionCompleteDate,
    this.resolvedDate,
    required this.totalBalance,
    required this.lateFees,
    required this.daysOverdue,
    this.notes,
    required this.createdAt,
    this.updatedAt,
    this.isActive = true,
  });

  factory DelinquencyStageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('DelinquencyStageModel data is null');
    }

    return DelinquencyStageModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'] ?? '',
      currentStage: DelinquencyStage.values.firstWhere(
        (e) => e.name == data['currentStage'],
        orElse: () => DelinquencyStage.current,
      ),
      stageDate: (data['stageDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      noticeSentDate: data['noticeSentDate'] != null
          ? (data['noticeSentDate'] as Timestamp).toDate()
          : null,
      finalNoticeSentDate: data['finalNoticeSentDate'] != null
          ? (data['finalNoticeSentDate'] as Timestamp).toDate()
          : null,
      lienFiledDate: data['lienFiledDate'] != null
          ? (data['lienFiledDate'] as Timestamp).toDate()
          : null,
      auctionScheduledDate: data['auctionScheduledDate'] != null
          ? (data['auctionScheduledDate'] as Timestamp).toDate()
          : null,
      auctionCompleteDate: data['auctionCompleteDate'] != null
          ? (data['auctionCompleteDate'] as Timestamp).toDate()
          : null,
      resolvedDate: data['resolvedDate'] != null
          ? (data['resolvedDate'] as Timestamp).toDate()
          : null,
      totalBalance: (data['totalBalance'] ?? 0.0).toDouble(),
      lateFees: (data['lateFees'] ?? 0.0).toDouble(),
      daysOverdue: data['daysOverdue'] ?? 0,
      notes: data['notes'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'tenantId': tenantId,
      'currentStage': currentStage.name,
      'stageDate': Timestamp.fromDate(stageDate),
      if (noticeSentDate != null) 'noticeSentDate': Timestamp.fromDate(noticeSentDate!),
      if (finalNoticeSentDate != null) 'finalNoticeSentDate': Timestamp.fromDate(finalNoticeSentDate!),
      if (lienFiledDate != null) 'lienFiledDate': Timestamp.fromDate(lienFiledDate!),
      if (auctionScheduledDate != null) 'auctionScheduledDate': Timestamp.fromDate(auctionScheduledDate!),
      if (auctionCompleteDate != null) 'auctionCompleteDate': Timestamp.fromDate(auctionCompleteDate!),
      if (resolvedDate != null) 'resolvedDate': Timestamp.fromDate(resolvedDate!),
      'totalBalance': totalBalance,
      'lateFees': lateFees,
      'daysOverdue': daysOverdue,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'isActive': isActive,
    };
  }

  DelinquencyStageModel copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    DelinquencyStage? currentStage,
    DateTime? stageDate,
    DateTime? noticeSentDate,
    DateTime? finalNoticeSentDate,
    DateTime? lienFiledDate,
    DateTime? auctionScheduledDate,
    DateTime? auctionCompleteDate,
    DateTime? resolvedDate,
    double? totalBalance,
    double? lateFees,
    int? daysOverdue,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isActive,
  }) {
    return DelinquencyStageModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      currentStage: currentStage ?? this.currentStage,
      stageDate: stageDate ?? this.stageDate,
      noticeSentDate: noticeSentDate ?? this.noticeSentDate,
      finalNoticeSentDate: finalNoticeSentDate ?? this.finalNoticeSentDate,
      lienFiledDate: lienFiledDate ?? this.lienFiledDate,
      auctionScheduledDate: auctionScheduledDate ?? this.auctionScheduledDate,
      auctionCompleteDate: auctionCompleteDate ?? this.auctionCompleteDate,
      resolvedDate: resolvedDate ?? this.resolvedDate,
      totalBalance: totalBalance ?? this.totalBalance,
      lateFees: lateFees ?? this.lateFees,
      daysOverdue: daysOverdue ?? this.daysOverdue,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isActive: isActive ?? this.isActive,
    );
  }

  String get stageDisplayName {
    switch (currentStage) {
      case DelinquencyStage.current:
        return 'Current';
      case DelinquencyStage.late:
        return 'Late';
      case DelinquencyStage.overdue:
        return 'Overdue';
      case DelinquencyStage.noticeSent:
        return 'Notice Sent';
      case DelinquencyStage.finalNotice:
        return 'Final Notice';
      case DelinquencyStage.lienFiled:
        return 'Lien Filed';
      case DelinquencyStage.auctionScheduled:
        return 'Auction Scheduled';
      case DelinquencyStage.auctionComplete:
        return 'Auction Complete';
      case DelinquencyStage.resolved:
        return 'Resolved';
    }
  }

  Color get stageColor {
    switch (currentStage) {
      case DelinquencyStage.current:
        return 'green';
      case DelinquencyStage.late:
        return 'yellow';
      case DelinquencyStage.overdue:
        return 'orange';
      case DelinquencyStage.noticeSent:
        return 'orange';
      case DelinquencyStage.finalNotice:
        return 'red';
      case DelinquencyStage.lienFiled:
        return 'red';
      case DelinquencyStage.auctionScheduled:
        return 'red';
      case DelinquencyStage.auctionComplete:
        return 'gray';
      case DelinquencyStage.resolved:
        return 'green';
    }
  }
}

// For backward compatibility, using String for color
typedef Color = String;

