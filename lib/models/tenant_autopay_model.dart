import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? _parseTimestamp(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is Map) {
    final seconds = (value['_seconds'] ?? value['seconds']) as int?;
    final nanoseconds = (value['_nanoseconds'] ?? value['nanoseconds']) as int? ?? 0;
    if (seconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000 + nanoseconds ~/ 1000000,
      );
    }
  }
  return null;
}

/// Autopay status: OFF | REQUESTED | ON
enum AutopayStatus {
  off,
  requested,
  on,
}

extension AutopayStatusX on AutopayStatus {
  String get value {
    switch (this) {
      case AutopayStatus.off:
        return 'OFF';
      case AutopayStatus.requested:
        return 'REQUESTED';
      case AutopayStatus.on:
        return 'ON';
    }
  }

  static AutopayStatus fromString(String? v) {
    switch (v) {
      case 'OFF':
        return AutopayStatus.off;
      case 'REQUESTED':
        return AutopayStatus.requested;
      case 'ON':
        return AutopayStatus.on;
      default:
        return AutopayStatus.off;
    }
  }
}

/// Who last updated autopay
enum AutopayUpdatedBy {
  tenant,
  facility,
  system,
}

extension AutopayUpdatedByX on AutopayUpdatedBy {
  String get value {
    switch (this) {
      case AutopayUpdatedBy.tenant:
        return 'TENANT';
      case AutopayUpdatedBy.facility:
        return 'FACILITY';
      case AutopayUpdatedBy.system:
        return 'SYSTEM';
    }
  }

  static AutopayUpdatedBy fromString(String? v) {
    switch (v) {
      case 'TENANT':
        return AutopayUpdatedBy.tenant;
      case 'FACILITY':
        return AutopayUpdatedBy.facility;
      case 'SYSTEM':
        return AutopayUpdatedBy.system;
      default:
        return AutopayUpdatedBy.system;
    }
  }
}

/// Tenant autopay state on Firestore
class TenantAutopayModel {
  final bool requested;
  final bool enabled;
  final AutopayStatus status;
  final DateTime? enabledAt;
  final DateTime? disabledAt;
  final String? disabledReason;
  final AutopayUpdatedBy updatedBy;
  final DateTime? updatedAt;

  /// Day of month (1–31) to run or schedule autopay; null = no override (use default billing).
  final int? chargeDayOfMonth;

  const TenantAutopayModel({
    this.requested = false,
    this.enabled = false,
    this.status = AutopayStatus.off,
    this.enabledAt,
    this.disabledAt,
    this.disabledReason,
    this.updatedBy = AutopayUpdatedBy.system,
    this.updatedAt,
    this.chargeDayOfMonth,
  });

  bool get isOn => status == AutopayStatus.on;
  bool get isRequested => status == AutopayStatus.requested;
  bool get isOff => status == AutopayStatus.off;

  factory TenantAutopayModel.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const TenantAutopayModel();
    int? day;
    final rawDay = data['chargeDayOfMonth'];
    if (rawDay is num) {
      final d = rawDay.toInt();
      if (d >= 1 && d <= 31) day = d;
    }
    return TenantAutopayModel(
      requested: data['requested'] == true,
      enabled: data['enabled'] == true,
      status: AutopayStatusX.fromString(data['status'] as String?),
      enabledAt: _parseTimestamp(data['enabledAt']),
      disabledAt: _parseTimestamp(data['disabledAt']),
      disabledReason: data['disabledReason'] as String?,
      updatedBy: AutopayUpdatedByX.fromString(data['updatedBy'] as String?),
      updatedAt: _parseTimestamp(data['updatedAt']),
      chargeDayOfMonth: day,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'requested': requested,
      'enabled': enabled,
      'status': status.value,
      if (enabledAt != null) 'enabledAt': Timestamp.fromDate(enabledAt!),
      if (disabledAt != null) 'disabledAt': Timestamp.fromDate(disabledAt!),
      if (disabledReason != null && disabledReason!.isNotEmpty) 'disabledReason': disabledReason,
      if (chargeDayOfMonth != null) 'chargeDayOfMonth': chargeDayOfMonth,
      'updatedBy': updatedBy.value,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}
