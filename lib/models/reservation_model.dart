import 'package:cloud_firestore/cloud_firestore.dart';

/// Reservation status
enum ReservationStatus {
  pending, // Initial reservation, not yet confirmed
  confirmed, // Reservation confirmed, waiting for move-in
  completed, // Move-in completed
  cancelled, // Reservation cancelled
  expired, // Reservation expired (time limit reached)
}

/// Public reservation for online move-in
class Reservation {
  final String id;
  final String facilityId;
  final String? unitId; // Optional: if unit is pre-selected
  final String? unitNumber; // Unit number if unit is selected
  final String email; // Customer email
  final String? phone; // Customer phone
  final String? name; // Customer name (if provided)
  final ReservationStatus status;
  final DateTime reservedAt;
  final DateTime? expiresAt; // Reservation expiration time
  final DateTime? moveInDate; // Intended move-in date
  final DateTime? completedAt; // When move-in was completed
  final String? moveInToken; // Token for completing move-in
  final Map<String, dynamic>? metadata; // Additional data (pricing, etc.)
  /// Lease PDF for online move-in (from facility contract template), when configured.
  final String? onlineMoveInLeaseTitle;
  final String? onlineMoveInLeaseUrl;

  const Reservation({
    required this.id,
    required this.facilityId,
    this.unitId,
    this.unitNumber,
    required this.email,
    this.phone,
    this.name,
    this.status = ReservationStatus.pending,
    required this.reservedAt,
    this.expiresAt,
    this.moveInDate,
    this.completedAt,
    this.moveInToken,
    this.metadata,
    this.onlineMoveInLeaseTitle,
    this.onlineMoveInLeaseUrl,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'unitId': unitId,
      'unitNumber': unitNumber,
      'email': email,
      'phone': phone,
      'name': name,
      'status': status.name,
      'reservedAt': Timestamp.fromDate(reservedAt),
      'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt!) : null,
      'moveInDate': moveInDate != null ? Timestamp.fromDate(moveInDate!) : null,
      'completedAt': completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      'moveInToken': moveInToken,
      'metadata': metadata,
      'onlineMoveInLeaseTitle': onlineMoveInLeaseTitle,
      'onlineMoveInLeaseUrl': onlineMoveInLeaseUrl,
    };
  }

  factory Reservation.fromMap(String id, Map<String, dynamic> map) {
    return Reservation(
      id: id,
      facilityId: map['facilityId'] as String,
      unitId: map['unitId'] as String?,
      unitNumber: map['unitNumber'] as String?,
      email: map['email'] as String,
      phone: map['phone'] as String?,
      name: map['name'] as String?,
      status: ReservationStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => ReservationStatus.pending,
      ),
      reservedAt: (map['reservedAt'] as Timestamp).toDate(),
      expiresAt: (map['expiresAt'] as Timestamp?)?.toDate(),
      moveInDate: (map['moveInDate'] as Timestamp?)?.toDate(),
      completedAt: (map['completedAt'] as Timestamp?)?.toDate(),
      moveInToken: map['moveInToken'] as String?,
      metadata: map['metadata'] as Map<String, dynamic>?,
      onlineMoveInLeaseTitle: map['onlineMoveInLeaseTitle'] as String?,
      onlineMoveInLeaseUrl: map['onlineMoveInLeaseUrl'] as String?,
    );
  }

  bool get isValid {
    if (status == ReservationStatus.completed || status == ReservationStatus.cancelled) {
      return false;
    }
    if (expiresAt != null && DateTime.now().isAfter(expiresAt!)) {
      return false;
    }
    return status == ReservationStatus.pending || status == ReservationStatus.confirmed;
  }
}

