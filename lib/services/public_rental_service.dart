import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/reservation_model.dart';
import 'package:sfcapp/models/unit_model.dart';

/// Service for public rental portal functionality
class PublicRentalService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Get available units for a facility (public view)
  static Future<List<UnitModel>> getAvailableUnits(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .where('status', isEqualTo: UnitStatus.available.name)
          .where('isActive', isEqualTo: true)
          .orderBy('monthlyRate')
          .get();

      return snapshot.docs.map((doc) => UnitModel.fromFirestore(doc)).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error getting available units: $e');
      }
      return [];
    }
  }

  /// Get facility public information
  static Future<FacilityModel?> getFacility(String facilityId) async {
    try {
      final doc =
          await _firestore.collection('facilities').doc(facilityId).get();

      if (!doc.exists) return null;

      return FacilityModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error getting facility: $e');
      }
      return null;
    }
  }

  /// Create a reservation
  static Future<Reservation> createReservation({
    required String facilityId,
    String? unitId,
    String? unitNumber,
    required String email,
    String? phone,
    String? name,
    DateTime? moveInDate,
    Map<String, dynamic>? metadata,
    Duration expirationDuration =
        const Duration(hours: 24), // Default 24 hour hold
  }) async {
    try {
      if (unitId == null || unitId.trim().isEmpty) {
        throw ArgumentError('unitId is required for a public reservation');
      }

      final callable = FirebaseFunctions.instance
          .httpsCallable('createPublicReservationHold');
      final holdMinutes =
          expirationDuration.inMinutes <= 0 ? 10 : expirationDuration.inMinutes;
      final response = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'unitId': unitId,
        'unitNumber': unitNumber,
        'email': email,
        'phone': phone,
        'name': name,
        'moveInDate': moveInDate?.toIso8601String(),
        'metadata': metadata,
        'holdMinutes': holdMinutes,
      });
      final payload = Map<String, dynamic>.from(response.data as Map);
      if (payload['success'] != true) {
        throw Exception('Reservation could not be created');
      }
      final moveInToken = payload['moveInToken']?.toString() ?? '';
      if (moveInToken.isEmpty) {
        throw Exception('Reservation creation returned no move-in token');
      }
      final expiresIso = payload['expiresAt']?.toString();
      return Reservation(
        id: payload['reservationId']?.toString() ?? '',
        facilityId: facilityId,
        unitId: unitId,
        unitNumber: unitNumber,
        email: email.toLowerCase().trim(),
        phone: phone?.trim(),
        name: name?.trim(),
        status: ReservationStatus.pending,
        reservedAt: DateTime.now(),
        expiresAt: expiresIso != null
            ? DateTime.tryParse(expiresIso)
            : DateTime.now().add(expirationDuration),
        moveInDate: moveInDate,
        moveInToken: moveInToken,
        metadata: metadata,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error creating reservation: $e');
      }
      rethrow;
    }
  }

  /// Get reservation by token
  static Future<Reservation?> getReservationByToken(String token) async {
    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('getPublicReservationByToken');
      final response =
          await callable.call(<String, dynamic>{'token': token.trim()});
      final payload = Map<String, dynamic>.from(response.data as Map);
      if (payload['found'] != true || payload['reservation'] is! Map) {
        return null;
      }
      final reservationMap =
          Map<String, dynamic>.from(payload['reservation'] as Map);
      final statusRaw = reservationMap['status']?.toString() ?? 'pending';
      final status = ReservationStatus.values.firstWhere(
        (s) => s.name == statusRaw,
        orElse: () => ReservationStatus.pending,
      );
      String? leaseTitle;
      String? leaseUrl;
      final lease = payload['onlineMoveInLease'];
      if (lease is Map) {
        leaseTitle = lease['title']?.toString();
        leaseUrl = lease['url']?.toString();
      }
      return Reservation(
        id: reservationMap['id']?.toString() ?? '',
        facilityId: reservationMap['facilityId']?.toString() ?? '',
        unitId: reservationMap['unitId']?.toString(),
        unitNumber: reservationMap['unitNumber']?.toString(),
        email: reservationMap['email']?.toString() ?? '',
        phone: reservationMap['phone']?.toString(),
        name: reservationMap['name']?.toString(),
        status: status,
        reservedAt:
            DateTime.tryParse(reservationMap['reservedAt']?.toString() ?? '') ??
                DateTime.now(),
        expiresAt:
            DateTime.tryParse(reservationMap['expiresAt']?.toString() ?? ''),
        moveInDate:
            DateTime.tryParse(reservationMap['moveInDate']?.toString() ?? ''),
        completedAt:
            DateTime.tryParse(reservationMap['completedAt']?.toString() ?? ''),
        moveInToken: reservationMap['moveInToken']?.toString(),
        metadata: reservationMap['metadata'] is Map
            ? Map<String, dynamic>.from(reservationMap['metadata'] as Map)
            : null,
        onlineMoveInLeaseTitle:
            (leaseTitle != null && leaseTitle.trim().isNotEmpty)
                ? leaseTitle.trim()
                : null,
        onlineMoveInLeaseUrl: (leaseUrl != null && leaseUrl.trim().isNotEmpty)
            ? leaseUrl.trim()
            : null,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error getting reservation: $e');
      }
      return null;
    }
  }

  /// Update reservation status
  static Future<void> updateReservationStatus({
    required String reservationId,
    required String moveInToken,
    required ReservationStatus status,
  }) async {
    try {
      if (status != ReservationStatus.cancelled) {
        throw ArgumentError(
            'Public reservations may only transition to cancelled');
      }
      final callable = FirebaseFunctions.instance
          .httpsCallable('transitionPublicReservationStatus');
      await callable.call(<String, dynamic>{
        'reservationId': reservationId,
        'moveInToken': moveInToken,
        'status': status.name,
      });

      if (kDebugMode) {
        print(
            '✅ [PublicRental] Updated reservation status: $reservationId to ${status.name}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error updating reservation: $e');
      }
      rethrow;
    }
  }

  /// Cancel a reservation
  static Future<void> cancelReservation(
      String reservationId, String moveInToken) {
    return updateReservationStatus(
      reservationId: reservationId,
      moveInToken: moveInToken,
      status: ReservationStatus.cancelled,
    );
  }

  /// Build public reservation URL
  static String buildReservationUrl(String token, {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/reserve?token=$token';
  }

  /// Build public move-in URL
  static String buildMoveInUrl(String token, {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/public-move-in?token=$token';
  }

  /// Complete public move-in (creates tenant, contract, processes payment)
  /// This calls a Cloud Function that handles the full move-in workflow
  static Future<Map<String, dynamic>> completePublicMoveIn({
    required String reservationId,
    required String token,
    required String name,
    required String email,
    required String phone,
    String? address,
    String? emergencyContactName,
    String? emergencyContactPhone,
    String?
        paymentIntentId, // Stripe payment intent ID if payment was processed
    double? totalAmount,
    List<Map<String, dynamic>>? lineItems, // Move-in charges breakdown
    bool skipPayment = false,
    String? signaturePngBase64,
    String? signatureSignedAt,
    String? addressLine2,
    String? city,
    String? state,
    String? zipCode,
    String? country,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    String? emergencyContactRelationship,
    String? emergencyContactEmail,
    String? notes,
    bool enrollAutopayInterest = false,
  }) async {
    try {
      // Call Cloud Function: completePublicMoveIn
      // The Cloud Function will:
      // 1. Validate the reservation token
      // 2. Create the tenant
      // 3. Create the contract
      // 4. Process payment (if provided)
      // 5. Complete the move-in workflow
      // 6. Update reservation status

      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('completePublicMoveIn');

      final result = await callable.call(<String, dynamic>{
        'reservationId': reservationId,
        'token': token,
        'name': name,
        'email': email,
        'phone': phone,
        'address': address,
        'emergencyContactName': emergencyContactName,
        'emergencyContactPhone': emergencyContactPhone,
        'paymentIntentId': paymentIntentId,
        'totalAmount': totalAmount,
        'lineItems': lineItems,
        'skipPayment': skipPayment,
        'signaturePngBase64': signaturePngBase64,
        'signatureSignedAt': signatureSignedAt,
        'addressLine2': addressLine2,
        'city': city,
        'state': state,
        'zipCode': zipCode,
        'country': country,
        'governmentIdType': governmentIdType,
        'governmentIdNumber': governmentIdNumber,
        'governmentIdState': governmentIdState,
        'governmentIdCountry': governmentIdCountry,
        'emergencyContactRelationship': emergencyContactRelationship,
        'emergencyContactEmail': emergencyContactEmail,
        'notes': notes,
        'enrollAutopayInterest': enrollAutopayInterest,
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

      final response = Map<String, dynamic>.from(result.data);

      if (kDebugMode) {
        print('✅ [PublicRental] Public move-in completed: $response');
      }

      return response;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error completing public move-in: $e');
      }
      rethrow;
    }
  }

  /// Create a Stripe Checkout session for public move-in.
  static Future<Map<String, dynamic>> createPublicMoveInCheckout({
    required String reservationId,
    required String token,
    required double amount,
    String? description,
  }) async {
    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('createPublicMoveInCheckout');
      final result = await callable.call(<String, dynamic>{
        'reservationId': reservationId,
        'token': token,
        'amount': amount,
        'description': description,
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () =>
            throw Exception('Request timed out. Please try again.'),
      );
      return Map<String, dynamic>.from(result.data as Map);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error creating public move-in checkout: $e');
      }
      rethrow;
    }
  }

  /// Validate a Stripe Checkout session for a public move-in and return payment details.
  static Future<Map<String, dynamic>> confirmPublicMoveInCheckout({
    required String reservationId,
    required String token,
    required String sessionId,
  }) async {
    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('confirmPublicMoveInCheckout');
      final result = await callable.call(<String, dynamic>{
        'reservationId': reservationId,
        'token': token,
        'sessionId': sessionId,
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () =>
            throw Exception('Request timed out. Please try again.'),
      );
      return Map<String, dynamic>.from(result.data as Map);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRental] Error confirming move-in checkout: $e');
      }
      rethrow;
    }
  }
}

extension ReservationExtension on Reservation {
  Reservation copyWith({
    String? id,
    String? facilityId,
    String? unitId,
    String? unitNumber,
    String? email,
    String? phone,
    String? name,
    ReservationStatus? status,
    DateTime? reservedAt,
    DateTime? expiresAt,
    DateTime? moveInDate,
    DateTime? completedAt,
    String? moveInToken,
    Map<String, dynamic>? metadata,
    String? onlineMoveInLeaseTitle,
    String? onlineMoveInLeaseUrl,
  }) {
    return Reservation(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      unitId: unitId ?? this.unitId,
      unitNumber: unitNumber ?? this.unitNumber,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      name: name ?? this.name,
      status: status ?? this.status,
      reservedAt: reservedAt ?? this.reservedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      moveInDate: moveInDate ?? this.moveInDate,
      completedAt: completedAt ?? this.completedAt,
      moveInToken: moveInToken ?? this.moveInToken,
      metadata: metadata ?? this.metadata,
      onlineMoveInLeaseTitle:
          onlineMoveInLeaseTitle ?? this.onlineMoveInLeaseTitle,
      onlineMoveInLeaseUrl: onlineMoveInLeaseUrl ?? this.onlineMoveInLeaseUrl,
    );
  }
}
