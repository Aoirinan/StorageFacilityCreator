import 'package:cloud_functions/cloud_functions.dart';
import '../models/tenant_model.dart';
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

  static Future<void> updateProfile({
    required String email,
    required String accessCode,
    String? phone,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
  }) async {
    final callable = _functions.httpsCallable('tenantUpdateProfile');
    try {
      final payload = <String, dynamic>{
        'email': email.trim(),
        'accessCode': accessCode.trim(),
        if (phone != null) 'phone': phone.trim(),
        if (emergencyContacts != null)
          'emergencyContacts': emergencyContacts.map((c) => c.toMap()).toList(),
        if (vehicles != null)
          'vehicles': vehicles.map((v) => v.toMap()).toList(),
      };
      await callable.call(payload);
    } on FirebaseFunctionsException catch (error) {
      throw TenantPortalException(
        message: error.message ?? 'Unable to update profile.',
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
