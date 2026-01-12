import 'package:cloud_firestore/cloud_firestore.dart';

enum LienStage {
  notStarted,
  noticeSent, // Pre-lien notice sent
  lienFiled, // Lien filed with county
  auctionScheduled, // Auction scheduled
  auctionComplete, // Auction completed
  resolved, // Lien resolved (paid or auctioned)
  cancelled, // Lien cancelled
}

enum LienStatus {
  active,
  resolved,
  cancelled,
}

class LienModel {
  final String id;
  final String facilityId;
  final String tenantId;
  final String unitId;
  final String contractId;
  final LienStage currentStage;
  final LienStatus status;
  final double totalAmount; // Total amount owed
  final double principalAmount; // Original amount
  final double lateFees; // Late fees included
  final double lienFilingFee; // Cost to file lien
  final double auctionFee; // Cost for auction (if applicable)
  
  // Legal dates
  final DateTime? noticeSentDate;
  final DateTime? lienFiledDate;
  final DateTime? auctionScheduledDate;
  final DateTime? auctionCompleteDate;
  final DateTime? resolvedDate;
  final DateTime? cancelledDate;
  
  // Legal tracking
  final String? lienNumber; // County lien number
  final String? county; // County where lien is filed
  final String? auctionCompany; // Auction company handling sale
  final String? auctionReference; // Reference number from auction company
  
  // Documents
  final String? noticePdfUrl; // Pre-lien notice PDF
  final String? lienFilingPdfUrl; // Lien filing document PDF
  final String? auctionNoticePdfUrl; // Auction notice PDF
  
  // Metadata
  final String? notes;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final bool isActive;

  const LienModel({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.unitId,
    required this.contractId,
    required this.currentStage,
    required this.status,
    required this.totalAmount,
    required this.principalAmount,
    required this.lateFees,
    this.lienFilingFee = 0.0,
    this.auctionFee = 0.0,
    this.noticeSentDate,
    this.lienFiledDate,
    this.auctionScheduledDate,
    this.auctionCompleteDate,
    this.resolvedDate,
    this.cancelledDate,
    this.lienNumber,
    this.county,
    this.auctionCompany,
    this.auctionReference,
    this.noticePdfUrl,
    this.lienFilingPdfUrl,
    this.auctionNoticePdfUrl,
    this.notes,
    this.metadata,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory LienModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('LienModel data is null');
    }

    return LienModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'] ?? '',
      unitId: data['unitId'] ?? '',
      contractId: data['contractId'] ?? '',
      currentStage: LienStage.values.firstWhere(
        (e) => e.name == data['currentStage'],
        orElse: () => LienStage.notStarted,
      ),
      status: LienStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => LienStatus.active,
      ),
      totalAmount: (data['totalAmount'] ?? 0.0).toDouble(),
      principalAmount: (data['principalAmount'] ?? 0.0).toDouble(),
      lateFees: (data['lateFees'] ?? 0.0).toDouble(),
      lienFilingFee: data['lienFilingFee'] != null ? (data['lienFilingFee'] as num).toDouble() : 0.0,
      auctionFee: data['auctionFee'] != null ? (data['auctionFee'] as num).toDouble() : 0.0,
      noticeSentDate: data['noticeSentDate'] != null
          ? (data['noticeSentDate'] as Timestamp).toDate()
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
      cancelledDate: data['cancelledDate'] != null
          ? (data['cancelledDate'] as Timestamp).toDate()
          : null,
      lienNumber: data['lienNumber'],
      county: data['county'],
      auctionCompany: data['auctionCompany'],
      auctionReference: data['auctionReference'],
      noticePdfUrl: data['noticePdfUrl'],
      lienFilingPdfUrl: data['lienFilingPdfUrl'],
      auctionNoticePdfUrl: data['auctionNoticePdfUrl'],
      notes: data['notes'],
      metadata: data['metadata'] != null
          ? Map<String, dynamic>.from(data['metadata'])
          : null,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      createdBy: data['createdBy'] ?? '',
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'tenantId': tenantId,
      'unitId': unitId,
      'contractId': contractId,
      'currentStage': currentStage.name,
      'status': status.name,
      'totalAmount': totalAmount,
      'principalAmount': principalAmount,
      'lateFees': lateFees,
      if (lienFilingFee != null) 'lienFilingFee': lienFilingFee,
      if (auctionFee != null) 'auctionFee': auctionFee,
      if (noticeSentDate != null) 'noticeSentDate': Timestamp.fromDate(noticeSentDate!),
      if (lienFiledDate != null) 'lienFiledDate': Timestamp.fromDate(lienFiledDate!),
      if (auctionScheduledDate != null) 'auctionScheduledDate': Timestamp.fromDate(auctionScheduledDate!),
      if (auctionCompleteDate != null) 'auctionCompleteDate': Timestamp.fromDate(auctionCompleteDate!),
      if (resolvedDate != null) 'resolvedDate': Timestamp.fromDate(resolvedDate!),
      if (cancelledDate != null) 'cancelledDate': Timestamp.fromDate(cancelledDate!),
      if (lienNumber != null && lienNumber!.isNotEmpty) 'lienNumber': lienNumber,
      if (county != null && county!.isNotEmpty) 'county': county,
      if (auctionCompany != null && auctionCompany!.isNotEmpty) 'auctionCompany': auctionCompany,
      if (auctionReference != null && auctionReference!.isNotEmpty) 'auctionReference': auctionReference,
      if (noticePdfUrl != null && noticePdfUrl!.isNotEmpty) 'noticePdfUrl': noticePdfUrl,
      if (lienFilingPdfUrl != null && lienFilingPdfUrl!.isNotEmpty) 'lienFilingPdfUrl': lienFilingPdfUrl,
      if (auctionNoticePdfUrl != null && auctionNoticePdfUrl!.isNotEmpty) 'auctionNoticePdfUrl': auctionNoticePdfUrl,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      if (metadata != null) 'metadata': metadata,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  LienModel copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    String? unitId,
    String? contractId,
    LienStage? currentStage,
    LienStatus? status,
    double? totalAmount,
    double? principalAmount,
    double? lateFees,
    double? lienFilingFee,
    double? auctionFee,
    DateTime? noticeSentDate,
    DateTime? lienFiledDate,
    DateTime? auctionScheduledDate,
    DateTime? auctionCompleteDate,
    DateTime? resolvedDate,
    DateTime? cancelledDate,
    String? lienNumber,
    String? county,
    String? auctionCompany,
    String? auctionReference,
    String? noticePdfUrl,
    String? lienFilingPdfUrl,
    String? auctionNoticePdfUrl,
    String? notes,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return LienModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      unitId: unitId ?? this.unitId,
      contractId: contractId ?? this.contractId,
      currentStage: currentStage ?? this.currentStage,
      status: status ?? this.status,
      totalAmount: totalAmount ?? this.totalAmount,
      principalAmount: principalAmount ?? this.principalAmount,
      lateFees: lateFees ?? this.lateFees,
      lienFilingFee: lienFilingFee ?? this.lienFilingFee,
      auctionFee: auctionFee ?? this.auctionFee,
      noticeSentDate: noticeSentDate ?? this.noticeSentDate,
      lienFiledDate: lienFiledDate ?? this.lienFiledDate,
      auctionScheduledDate: auctionScheduledDate ?? this.auctionScheduledDate,
      auctionCompleteDate: auctionCompleteDate ?? this.auctionCompleteDate,
      resolvedDate: resolvedDate ?? this.resolvedDate,
      cancelledDate: cancelledDate ?? this.cancelledDate,
      lienNumber: lienNumber ?? this.lienNumber,
      county: county ?? this.county,
      auctionCompany: auctionCompany ?? this.auctionCompany,
      auctionReference: auctionReference ?? this.auctionReference,
      noticePdfUrl: noticePdfUrl ?? this.noticePdfUrl,
      lienFilingPdfUrl: lienFilingPdfUrl ?? this.lienFilingPdfUrl,
      auctionNoticePdfUrl: auctionNoticePdfUrl ?? this.auctionNoticePdfUrl,
      notes: notes ?? this.notes,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  String get stageDisplayName {
    switch (currentStage) {
      case LienStage.notStarted:
        return 'Not Started';
      case LienStage.noticeSent:
        return 'Notice Sent';
      case LienStage.lienFiled:
        return 'Lien Filed';
      case LienStage.auctionScheduled:
        return 'Auction Scheduled';
      case LienStage.auctionComplete:
        return 'Auction Complete';
      case LienStage.resolved:
        return 'Resolved';
      case LienStage.cancelled:
        return 'Cancelled';
    }
  }

  String get statusDisplayName {
    switch (status) {
      case LienStatus.active:
        return 'Active';
      case LienStatus.resolved:
        return 'Resolved';
      case LienStatus.cancelled:
        return 'Cancelled';
    }
  }

  String get formattedTotal => '\$${totalAmount.toStringAsFixed(2)}';
  bool get isActiveLien => status == LienStatus.active && currentStage != LienStage.resolved && currentStage != LienStage.cancelled;
}

