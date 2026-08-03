class CancellationReasonOption {
  final String id;
  final String label;

  const CancellationReasonOption({required this.id, required this.label});

  factory CancellationReasonOption.fromMap(Map<String, dynamic> map) {
    return CancellationReasonOption(
      id: (map['id'] ?? '').toString(),
      label: (map['label'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {'id': id, 'label': label};
}

class CancellationPromo {
  final String id;
  final List<String> planTypes;
  final String title;
  final String body;
  final int? percentOff;
  final int? amountOffCents;
  final int durationMonths;
  final bool active;
  final String? stripeCouponId;
  final int sortOrder;

  const CancellationPromo({
    required this.id,
    required this.planTypes,
    required this.title,
    required this.body,
    this.percentOff,
    this.amountOffCents,
    required this.durationMonths,
    required this.active,
    this.stripeCouponId,
    this.sortOrder = 0,
  });

  factory CancellationPromo.fromMap(Map<String, dynamic> map) {
    return CancellationPromo(
      id: (map['id'] ?? '').toString(),
      planTypes: (map['planTypes'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      title: (map['title'] ?? '').toString(),
      body: (map['body'] ?? '').toString(),
      percentOff: (map['percentOff'] as num?)?.toInt(),
      amountOffCents: (map['amountOffCents'] as num?)?.toInt(),
      durationMonths: (map['durationMonths'] as num?)?.toInt() ?? 1,
      active: map['active'] == true,
      stripeCouponId: map['stripeCouponId']?.toString(),
      sortOrder: (map['sortOrder'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'planTypes': planTypes,
        'title': title,
        'body': body,
        if (percentOff != null) 'percentOff': percentOff,
        if (amountOffCents != null) 'amountOffCents': amountOffCents,
        'durationMonths': durationMonths,
        'active': active,
        'stripeCouponId': stripeCouponId,
        'sortOrder': sortOrder,
      };

  CancellationPromo copyWith({
    String? id,
    List<String>? planTypes,
    String? title,
    String? body,
    int? percentOff,
    int? amountOffCents,
    int? durationMonths,
    bool? active,
    String? stripeCouponId,
    int? sortOrder,
  }) {
    return CancellationPromo(
      id: id ?? this.id,
      planTypes: planTypes ?? this.planTypes,
      title: title ?? this.title,
      body: body ?? this.body,
      percentOff: percentOff ?? this.percentOff,
      amountOffCents: amountOffCents ?? this.amountOffCents,
      durationMonths: durationMonths ?? this.durationMonths,
      active: active ?? this.active,
      stripeCouponId: stripeCouponId ?? this.stripeCouponId,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class CancellationRetentionConfig {
  final List<CancellationReasonOption> primaryReasons;
  final Map<String, List<CancellationReasonOption>> detailReasonsByPrimary;
  final List<CancellationPromo> promos;
  final List<String> platformLossCopy;
  final List<String> websiteLossCopy;

  const CancellationRetentionConfig({
    required this.primaryReasons,
    required this.detailReasonsByPrimary,
    required this.promos,
    required this.platformLossCopy,
    required this.websiteLossCopy,
  });

  factory CancellationRetentionConfig.fromMap(Map<String, dynamic> map) {
    final detailRaw =
        map['detailReasonsByPrimary'] as Map<String, dynamic>? ?? const {};
    final detail = <String, List<CancellationReasonOption>>{};
    for (final entry in detailRaw.entries) {
      final list = (entry.value as List<dynamic>? ?? const [])
          .map((e) => CancellationReasonOption.fromMap(
                Map<String, dynamic>.from(e as Map),
              ))
          .toList();
      detail[entry.key] = list;
    }
    final loss =
        map['lossCopy'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    return CancellationRetentionConfig(
      primaryReasons: (map['primaryReasons'] as List<dynamic>? ?? const [])
          .map((e) => CancellationReasonOption.fromMap(
                Map<String, dynamic>.from(e as Map),
              ))
          .toList(),
      detailReasonsByPrimary: detail,
      promos: (map['promos'] as List<dynamic>? ?? const [])
          .map((e) =>
              CancellationPromo.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      platformLossCopy: (loss['platform'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      websiteLossCopy: (loss['website'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  Map<String, dynamic> toMap() => {
        'primaryReasons': primaryReasons.map((e) => e.toMap()).toList(),
        'detailReasonsByPrimary': detailReasonsByPrimary.map(
          (key, value) => MapEntry(key, value.map((e) => e.toMap()).toList()),
        ),
        'promos': promos.map((e) => e.toMap()).toList(),
        'lossCopy': {
          'platform': platformLossCopy,
          'website': websiteLossCopy,
        },
      };

  List<String> lossCopyFor(String planType) =>
      planType == 'website' ? websiteLossCopy : platformLossCopy;
}

class CancellationEventRow {
  final String id;
  final String? facilityId;
  final String? accountId;
  final String? planType;
  final String? primaryReason;
  final String? detailReason;
  final String? outcome;
  final String? promoIdAccepted;
  final DateTime? createdAt;
  final DateTime? completedAt;

  const CancellationEventRow({
    required this.id,
    this.facilityId,
    this.accountId,
    this.planType,
    this.primaryReason,
    this.detailReason,
    this.outcome,
    this.promoIdAccepted,
    this.createdAt,
    this.completedAt,
  });

  factory CancellationEventRow.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic value) {
      if (value is String && value.isNotEmpty) {
        return DateTime.tryParse(value);
      }
      return null;
    }

    return CancellationEventRow(
      id: (map['id'] ?? '').toString(),
      facilityId: map['facilityId']?.toString(),
      accountId: map['accountId']?.toString(),
      planType: map['planType']?.toString(),
      primaryReason: map['primaryReason']?.toString(),
      detailReason: map['detailReason']?.toString(),
      outcome: map['outcome']?.toString(),
      promoIdAccepted: map['promoIdAccepted']?.toString(),
      createdAt: parseDate(map['createdAt']),
      completedAt: parseDate(map['completedAt']),
    );
  }
}
