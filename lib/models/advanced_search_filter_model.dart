import 'package:cloud_firestore/cloud_firestore.dart';

/// Entity types that can be searched
enum SearchEntityType {
  tenants,
  units,
  payments,
  facilities,
  all, // Search across all types
}

/// Filter operators for advanced search
enum FilterOperator {
  equals,
  contains,
  startsWith,
  greaterThan,
  lessThan,
  between,
  inList,
}

/// Individual search filter
class SearchFilter {
  final String field;
  final FilterOperator operator;
  final dynamic value; // Can be String, int, double, List, DateTime, etc.
  final dynamic value2; // For 'between' operator

  const SearchFilter({
    required this.field,
    required this.operator,
    this.value,
    this.value2,
  });

  Map<String, dynamic> toMap() {
    return {
      'field': field,
      'operator': operator.name,
      'value': value is DateTime ? Timestamp.fromDate(value) : value,
      'value2': value2 is DateTime ? Timestamp.fromDate(value2) : value2,
    };
  }

  factory SearchFilter.fromMap(Map<String, dynamic> map) {
    return SearchFilter(
      field: map['field'] as String,
      operator: FilterOperator.values.firstWhere(
        (op) => op.name == map['operator'],
        orElse: () => FilterOperator.contains,
      ),
      value: map['value'],
      value2: map['value2'],
    );
  }
}

/// Advanced search criteria
class AdvancedSearchCriteria {
  final SearchEntityType entityType;
  final List<SearchFilter> filters;
  final String? facilityId; // Optional: limit to specific facility
  final int? limit;
  final String? sortBy;
  final bool sortDescending;

  const AdvancedSearchCriteria({
    required this.entityType,
    this.filters = const [],
    this.facilityId,
    this.limit,
    this.sortBy,
    this.sortDescending = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'entityType': entityType.name,
      'filters': filters.map((f) => f.toMap()).toList(),
      'facilityId': facilityId,
      'limit': limit,
      'sortBy': sortBy,
      'sortDescending': sortDescending,
    };
  }

  factory AdvancedSearchCriteria.fromMap(Map<String, dynamic> map) {
    return AdvancedSearchCriteria(
      entityType: SearchEntityType.values.firstWhere(
        (et) => et.name == map['entityType'],
        orElse: () => SearchEntityType.all,
      ),
      filters: (map['filters'] as List<dynamic>?)
              ?.map((f) => SearchFilter.fromMap(f as Map<String, dynamic>))
              .toList() ??
          [],
      facilityId: map['facilityId'] as String?,
      limit: map['limit'] as int?,
      sortBy: map['sortBy'] as String?,
      sortDescending: map['sortDescending'] as bool? ?? false,
    );
  }

  AdvancedSearchCriteria copyWith({
    SearchEntityType? entityType,
    List<SearchFilter>? filters,
    String? facilityId,
    int? limit,
    String? sortBy,
    bool? sortDescending,
  }) {
    return AdvancedSearchCriteria(
      entityType: entityType ?? this.entityType,
      filters: filters ?? this.filters,
      facilityId: facilityId ?? this.facilityId,
      limit: limit ?? this.limit,
      sortBy: sortBy ?? this.sortBy,
      sortDescending: sortDescending ?? this.sortDescending,
    );
  }
}

/// Saved search filter (for reusing searches)
class SavedSearchFilter {
  final String id;
  final String name;
  final String? description;
  final AdvancedSearchCriteria criteria;
  final String facilityId;
  final String createdBy;
  final DateTime createdAt;
  final DateTime? lastUsed;

  const SavedSearchFilter({
    required this.id,
    required this.name,
    this.description,
    required this.criteria,
    required this.facilityId,
    required this.createdBy,
    required this.createdAt,
    this.lastUsed,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'criteria': criteria.toMap(),
      'facilityId': facilityId,
      'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastUsed': lastUsed != null ? Timestamp.fromDate(lastUsed!) : null,
    };
  }

  factory SavedSearchFilter.fromMap(String id, Map<String, dynamic> map) {
    return SavedSearchFilter(
      id: id,
      name: map['name'] as String,
      description: map['description'] as String?,
      criteria: AdvancedSearchCriteria.fromMap(
        map['criteria'] as Map<String, dynamic>,
      ),
      facilityId: map['facilityId'] as String,
      createdBy: map['createdBy'] as String,
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      lastUsed: (map['lastUsed'] as Timestamp?)?.toDate(),
    );
  }
}

