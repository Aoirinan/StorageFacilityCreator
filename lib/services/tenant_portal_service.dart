import 'package:cloud_functions/cloud_functions.dart';
import '../models/reservation_model.dart';
import '../models/tenant_model.dart';
import '../models/tenant_portal_models.dart';

class TenantPortalService {
  TenantPortalService._();

  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Available units for "Rent another unit" (server-side; portal users cannot read `units` in Firestore).
  static Future<List<TenantPortalAvailableUnit>> listAvailableUnitsForAdditionalRental({
    required String email,
    required String accessCode,
    required String facilityId,
  }) async {
    final callable = _functions.httpsCallable('tenantPortalListAvailableUnits');
    try {
      final result = await callable.call(<String, dynamic>{
        'email': email.trim(),
        'accessCode': accessCode.trim(),
        'facilityId': facilityId.trim(),
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final raw = data['units'] as List<dynamic>? ?? const [];
      return raw
          .map((e) => TenantPortalAvailableUnit.fromMap(
                Map<String, dynamic>.from(e as Map),
              ))
          .where((u) => u.id.isNotEmpty)
          .toList();
    } on FirebaseFunctionsException catch (error) {
      throw TenantPortalException(
        message: error.message ?? 'Unable to load available units.',
        code: error.code,
      );
    } catch (error) {
      throw TenantPortalException(
        message: error.toString(),
        code: 'unknown',
      );
    }
  }

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

  static Future<Reservation> createAdditionalUnitReservation({
    required String email,
    required String accessCode,
    required String facilityId,
    required String unitId,
    String? unitNumber,
    DateTime? moveInDate,
  }) async {
    final callable = _functions.httpsCallable('createTenantPortalAdditionalUnitHold');
    try {
      final result = await callable.call(<String, dynamic>{
        'email': email.trim(),
        'accessCode': accessCode.trim(),
        'facilityId': facilityId,
        'unitId': unitId,
        'unitNumber': unitNumber,
        'moveInDate': moveInDate?.toIso8601String(),
      });
      final payload = Map<String, dynamic>.from(result.data as Map);
      if (payload['success'] != true) {
        throw TenantPortalException(
          message: 'Unable to start rental hold.',
          code: 'unknown',
        );
      }
      final token = payload['moveInToken']?.toString() ?? '';
      final reservationId = payload['reservationId']?.toString() ?? '';
      return Reservation(
        id: reservationId,
        facilityId: facilityId,
        unitId: unitId,
        unitNumber: unitNumber,
        email: email.toLowerCase().trim(),
        status: ReservationStatus.pending,
        reservedAt: DateTime.now(),
        expiresAt: DateTime.tryParse(payload['expiresAt']?.toString() ?? ''),
        moveInDate: moveInDate,
        moveInToken: token,
        metadata: const {'source': 'tenant_portal_additional_unit'},
      );
    } on FirebaseFunctionsException catch (error) {
      throw TenantPortalException(
        message: error.message ?? 'Unable to start unit rental.',
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
