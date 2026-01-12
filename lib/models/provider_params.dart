import 'package:flutter/foundation.dart';

@immutable
class FacilityTenantParams {
  final String facilityId;
  final String tenantId;

  const FacilityTenantParams({
    required this.facilityId,
    required this.tenantId,
  });

  bool get isValid => facilityId.isNotEmpty && tenantId.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FacilityTenantParams &&
          facilityId == other.facilityId &&
          tenantId == other.tenantId;

  @override
  int get hashCode => Object.hash(facilityId, tenantId);
}

