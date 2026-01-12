import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents an address (mailing, alternate, or other)
class Address {
  final String id;
  final AddressType type;
  final String street1;
  final String? street2;
  final String city;
  final String state;
  final String zipCode;
  final String? country;
  final bool isPrimary;
  final String? notes;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const Address({
    required this.id,
    required this.type,
    required this.street1,
    this.street2,
    required this.city,
    required this.state,
    required this.zipCode,
    this.country,
    this.isPrimary = false,
    this.notes,
    required this.createdAt,
    this.updatedAt,
  });

  factory Address.fromMap(Map<String, dynamic> data) {
    return Address(
      id: data['id'] ?? '',
      type: AddressType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => AddressType.mailing,
      ),
      street1: (data['street1'] as String? ?? '').trim(),
      street2: (data['street2'] as String?)?.trim(),
      city: (data['city'] as String? ?? '').trim(),
      state: (data['state'] as String? ?? '').trim(),
      zipCode: (data['zipCode'] as String? ?? '').trim(),
      country: (data['country'] as String?)?.trim(),
      isPrimary: data['isPrimary'] ?? false,
      notes: (data['notes'] as String?)?.trim(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'street1': street1,
      if (street2 != null && street2!.isNotEmpty) 'street2': street2,
      'city': city,
      'state': state,
      'zipCode': zipCode,
      if (country != null && country!.isNotEmpty) 'country': country,
      'isPrimary': isPrimary,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  String get formattedAddress {
    final parts = <String>[
      street1,
      if (street2 != null && street2!.isNotEmpty) street2!,
      '$city, $state $zipCode',
      if (country != null && country!.isNotEmpty) country!,
    ];
    return parts.join('\n');
  }

  String get singleLineAddress {
    final parts = <String>[
      street1,
      if (street2 != null && street2!.isNotEmpty) street2!,
      '$city, $state $zipCode',
    ];
    return parts.join(', ');
  }

  Address copyWith({
    String? id,
    AddressType? type,
    String? street1,
    String? street2,
    String? city,
    String? state,
    String? zipCode,
    String? country,
    bool? isPrimary,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Address(
      id: id ?? this.id,
      type: type ?? this.type,
      street1: street1 ?? this.street1,
      street2: street2 ?? this.street2,
      city: city ?? this.city,
      state: state ?? this.state,
      zipCode: zipCode ?? this.zipCode,
      country: country ?? this.country,
      isPrimary: isPrimary ?? this.isPrimary,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

enum AddressType {
  mailing,
  alternate,
  billing,
  other,
}

