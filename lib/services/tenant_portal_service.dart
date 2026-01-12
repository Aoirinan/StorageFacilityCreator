import 'package:cloud_functions/cloud_functions.dart';
import '../models/tenant_portal_models.dart';

class TenantPortalService {
  TenantPortalService._();

  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static Future<TenantPortalData> fetchPortalData({
    required String email,
    required String accessCode,
  }) async {
    final callable = _functions.httpsCallable('tenantPortalFetch');
    try {
      final result = await callable.call({
        'email': email.trim(),
        'accessCode': accessCode.trim(),
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      return TenantPortalData.fromMap(data);
    } on FirebaseFunctionsException catch (error) {
      throw TenantPortalException(
        message: error.message ?? 'Unable to load tenant portal data.',
        code: error.code,
      );
    } catch (error) {
      throw TenantPortalException(
        message: error.toString(),
        code: 'unknown',
      );
    }
  }
}

class TenantPortalException implements Exception {
  final String message;
  final String code;

  TenantPortalException({required this.message, required this.code});

  @override
  String toString() => 'TenantPortalException($code): $message';
}
