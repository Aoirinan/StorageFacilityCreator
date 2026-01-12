import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/tenant_portal_models.dart';
import '../services/tenant_portal_service.dart';

class TenantPortalLookup {
  final String email;
  final String accessCode;

  const TenantPortalLookup({
    required this.email,
    required this.accessCode,
  });
}

final tenantPortalProvider = FutureProvider.autoDispose.family<TenantPortalData, TenantPortalLookup>((ref, lookup) async {
  return TenantPortalService.fetchPortalData(
    email: lookup.email,
    accessCode: lookup.accessCode,
  );
});
