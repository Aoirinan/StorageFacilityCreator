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

  /// The printable lines of this address, from the parts that are filled in:
  /// street1, street2, then "City, ST 12345" built only from the city, state
  /// and ZIP that are present, then the country when it is not the US
  /// (online move-ins store "US" on every address). Never an empty line, a
  /// lone comma or a double space; empty when nothing is filled in.
  List<String> get addressLines {
    final s1 = _tidy(street1);
    final s2 = _tidy(street2);
    final c = _tidy(country);
    return [
      if (s1.isNotEmpty) s1,
      if (s2.isNotEmpty) s2,
      if (localityLine.isNotEmpty) localityLine,
      if (c.isNotEmpty && !_isUnitedStates(c)) c,
    ];
  }

  /// "City, ST 12345" from whichever of city, state and ZIP are present:
  /// "City, ST", "City 12345", "ST 12345", or "" when all three are blank.
  String get localityLine {
    final c = _tidy(city);
    final s = _tidy(state);
    final z = _tidy(zipCode);
    var line = c;
    if (s.isNotEmpty) line = line.isEmpty ? s : '$line, $s';
    if (z.isNotEmpty) line = line.isEmpty ? z : '$line $z';
    return line;
  }

  /// [addressLines] one per line, for printed documents. Empty when the
  /// address has nothing filled in.
  String get formattedAddress => addressLines.join('\n');

  /// Street, street2 and "City, ST 12345" on one line, comma separated
  /// (no country). Empty when the address has nothing filled in.
  String get singleLineAddress {
    final s1 = _tidy(street1);
    final s2 = _tidy(street2);
    return [
      if (s1.isNotEmpty) s1,
      if (s2.isNotEmpty) s2,
      if (localityLine.isNotEmpty) localityLine,
    ].join(', ');
  }

  /// Trims [s] and collapses runs of whitespace (including line breaks) to a
  /// single space.
  static String _tidy(String? s) =>
      (s ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');

  static bool _isUnitedStates(String country) {
    final c = country.toUpperCase().replaceAll('.', '').replaceAll(' ', '');
    return c == 'US' ||
        c == 'USA' ||
        c == 'UNITEDSTATES' ||
        c == 'UNITEDSTATESOFAMERICA';
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

