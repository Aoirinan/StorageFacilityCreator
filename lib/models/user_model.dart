import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String email;
  final bool tosAccepted;
  final DateTime? tosAcceptedAt;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;
  final String? activeFacilityId; // Active facility ID (null = All Facilities)
  final bool twoFactorEnabled; // Whether 2FA is enabled for this user
  final DateTime? lastOTPSentAt; // Last time an OTP was sent (for rate limiting)
  final bool authDisabled; // Set by super admin when disabling Auth (cannot sign in)

  UserModel({
    required this.uid,
    required this.email,
    required this.tosAccepted,
    this.tosAcceptedAt,
    this.createdAt,
    this.lastLoginAt,
    this.activeFacilityId,
    this.twoFactorEnabled = false,
    this.lastOTPSentAt,
    this.authDisabled = false,
  });

  // Create UserModel from Firestore document
  factory UserModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    
    return UserModel(
      uid: doc.id,
      email: data?['email'] ?? '',
      tosAccepted: data?['tosAccepted'] ?? false,
      tosAcceptedAt: (data?['tosAcceptedAt'] as Timestamp?)?.toDate(),
      createdAt: (data?['createdAt'] as Timestamp?)?.toDate(),
      lastLoginAt: (data?['lastLoginAt'] as Timestamp?)?.toDate(),
      activeFacilityId: data?['activeFacilityId'] as String?,
      twoFactorEnabled: data?['twoFactorEnabled'] ?? false,
      lastOTPSentAt: (data?['lastOTPSentAt'] as Timestamp?)?.toDate(),
      authDisabled: data?['authDisabled'] ?? false,
    );
  }

  // Convert UserModel to Map for Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'email': email,
      'tosAccepted': tosAccepted,
      'tosAcceptedAt': tosAcceptedAt != null ? Timestamp.fromDate(tosAcceptedAt!) : null,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : FieldValue.serverTimestamp(),
      'lastLoginAt': lastLoginAt != null ? Timestamp.fromDate(lastLoginAt!) : FieldValue.serverTimestamp(),
      'activeFacilityId': activeFacilityId,
      'twoFactorEnabled': twoFactorEnabled,
      'lastOTPSentAt': lastOTPSentAt != null ? Timestamp.fromDate(lastOTPSentAt!) : null,
    };
  }

  // Copy with method for updates
  UserModel copyWith({
    String? uid,
    String? email,
    bool? tosAccepted,
    DateTime? tosAcceptedAt,
    DateTime? createdAt,
    DateTime? lastLoginAt,
    String? activeFacilityId,
    bool? twoFactorEnabled,
    DateTime? lastOTPSentAt,
    bool? authDisabled,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      tosAccepted: tosAccepted ?? this.tosAccepted,
      tosAcceptedAt: tosAcceptedAt ?? this.tosAcceptedAt,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      activeFacilityId: activeFacilityId ?? this.activeFacilityId,
      twoFactorEnabled: twoFactorEnabled ?? this.twoFactorEnabled,
      lastOTPSentAt: lastOTPSentAt ?? this.lastOTPSentAt,
      authDisabled: authDisabled ?? this.authDisabled,
    );
  }

  @override
  String toString() {
    return 'UserModel(uid: $uid, email: $email, tosAccepted: $tosAccepted, createdAt: $createdAt)';
  }
}
