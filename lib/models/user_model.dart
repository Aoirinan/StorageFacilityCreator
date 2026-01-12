import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String email;
  final bool tosAccepted;
  final DateTime? tosAcceptedAt;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;

  UserModel({
    required this.uid,
    required this.email,
    required this.tosAccepted,
    this.tosAcceptedAt,
    this.createdAt,
    this.lastLoginAt,
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
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      tosAccepted: tosAccepted ?? this.tosAccepted,
      tosAcceptedAt: tosAcceptedAt ?? this.tosAcceptedAt,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
    );
  }

  @override
  String toString() {
    return 'UserModel(uid: $uid, email: $email, tosAccepted: $tosAccepted, createdAt: $createdAt)';
  }
}
