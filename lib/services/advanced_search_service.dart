import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/advanced_search_filter_model.dart';
import '../models/tenant_model.dart';
import '../models/unit_model.dart';
import '../models/facility_model.dart';
import 'facility_service.dart';
import 'tenant_service.dart';
import 'unit_service.dart';

/// Advanced search service with multi-criteria filtering
class AdvancedSearchService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Perform advanced search based on criteria
  static Future<List<Map<String, dynamic>>> search({
    required AdvancedSearchCriteria criteria,
    required String ownerUid,
  }) async {
    try {
      final results = <Map<String, dynamic>>[];

      switch (criteria.entityType) {
        case SearchEntityType.tenants:
          results.addAll(await _searchTenants(criteria, ownerUid));
          break;
        case SearchEntityType.units:
          results.addAll(await _searchUnits(criteria, ownerUid));
          break;
        case SearchEntityType.payments:
          results.addAll(await _searchPayments(criteria, ownerUid));
          break;
        case SearchEntityType.facilities:
          results.addAll(await _searchFacilities(criteria, ownerUid));
          break;
        case SearchEntityType.all:
          // Search all entity types
          final allResults = await Future.wait([
            _searchTenants(criteria, ownerUid),
            _searchUnits(criteria, ownerUid),
            _searchFacilities(criteria, ownerUid),
            _searchPayments(criteria, ownerUid),
          ]);
          results.addAll(allResults.expand((e) => e));
          break;
      }

      // Apply sorting if specified
      if (criteria.sortBy != null && results.isNotEmpty) {
        results.sort((a, b) {
          final aValue = a[criteria.sortBy!];
          final bValue = b[criteria.sortBy!];
          final comparison = _compareValues(aValue, bValue);
          return criteria.sortDescending ? -comparison : comparison;
        });
      }

      // Apply limit
      if (criteria.limit != null && results.length > criteria.limit!) {
        return results.take(criteria.limit!).toList();
      }

      return results;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AdvancedSearch] Error performing search: $e');
      }
      rethrow;
    }
  }

  /// Search tenants with advanced filters
  static Future<List<Map<String, dynamic>>> _searchTenants(
    AdvancedSearchCriteria criteria,
    String ownerUid,
  ) async {
    try {
      // Get facility IDs to search
      List<String> facilityIds;
      if (criteria.facilityId != null) {
        facilityIds = [criteria.facilityId!];
      } else {
        final facilities = await FacilityService.getUserFacilities();
        facilityIds = facilities.map((f) => f.id).toList();
      }

      if (facilityIds.isEmpty) return [];

      final allTenants = <TenantModel>[];

      // Get tenants from all facilities
      for (final facilityId in facilityIds) {
        try {
          final tenants = await TenantService.getTenantsForFacility(facilityId);
          allTenants.addAll(tenants);
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ [AdvancedSearch] Error loading tenants for facility $facilityId: $e');
          }
        }
      }

      // Apply filters
      var filteredTenants = allTenants;
      for (final filter in criteria.filters) {
        filteredTenants = filteredTenants.where((tenant) {
          return _matchesFilter(tenant.toFirestore(), filter);
        }).toList();
      }

      // Convert to result maps
      return filteredTenants.map((tenant) {
        return {
          'entityType': 'tenant',
          'id': tenant.id,
          'facilityId': tenant.facilityId,
          'name': tenant.name,
          'email': tenant.email,
          'phone': tenant.phone,
          'unitNumber': tenant.unitNumber,
          'monthlyRate': tenant.monthlyRate,
          'isActive': tenant.isActive,
          'data': tenant.toFirestore(),
        };
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AdvancedSearch] Error searching tenants: $e');
      }
      return [];
    }
  }

  /// Search units with advanced filters
  static Future<List<Map<String, dynamic>>> _searchUnits(
    AdvancedSearchCriteria criteria,
    String ownerUid,
  ) async {
    try {
      // Get facility IDs to search
      List<String> facilityIds;
      if (criteria.facilityId != null) {
        facilityIds = [criteria.facilityId!];
      } else {
        final facilities = await FacilityService.getUserFacilities();
        facilityIds = facilities.map((f) => f.id).toList();
      }

      if (facilityIds.isEmpty) return [];

      final allUnits = <UnitModel>[];

      // Get units from all facilities
      for (final facilityId in facilityIds) {
        try {
          final units = await UnitService.getUnitsForFacility(facilityId);
          allUnits.addAll(units);
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ [AdvancedSearch] Error loading units for facility $facilityId: $e');
          }
        }
      }

      // Apply filters
      var filteredUnits = allUnits;
      for (final filter in criteria.filters) {
        filteredUnits = filteredUnits.where((unit) {
          return _matchesFilter(_unitToMap(unit), filter);
        }).toList();
      }

      // Convert to result maps
      return filteredUnits.map((unit) {
        return {
          'entityType': 'unit',
          'id': unit.id,
          'facilityId': unit.facilityId,
          'unitNumber': unit.unitNumber,
          'status': unit.status.name,
          'monthlyRate': unit.monthlyRate,
          'tenantName': unit.tenantName,
          'data': _unitToMap(unit),
        };
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AdvancedSearch] Error searching units: $e');
      }
      return [];
    }
  }

  /// Search facilities with advanced filters
  static Future<List<Map<String, dynamic>>> _searchFacilities(
    AdvancedSearchCriteria criteria,
    String ownerUid,
  ) async {
    try {
      final facilities = await FacilityService.getUserFacilities();

      // Apply filters
      var filteredFacilities = facilities;
      for (final filter in criteria.filters) {
        filteredFacilities = filteredFacilities.where((facility) {
          return _matchesFilter(_facilityToMap(facility), filter);
        }).toList();
      }

      // Convert to result maps
      return filteredFacilities.map((facility) {
        return {
          'entityType': 'facility',
          'id': facility.id,
          'name': facility.name,
          'address': facility.address,
          'active': facility.active,
          'data': _facilityToMap(facility),
        };
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AdvancedSearch] Error searching facilities: $e');
      }
      return [];
    }
  }

  /// Search payments with advanced filters
  static Future<List<Map<String, dynamic>>> _searchPayments(
    AdvancedSearchCriteria criteria,
    String ownerUid,
  ) async {
    // Payment search would require PaymentService - for now return empty
    // This can be enhanced when payment search is needed
    if (kDebugMode) {
      print('⚠️ [AdvancedSearch] Payment search not yet implemented');
    }
    return [];
  }

  /// Check if a data object matches a filter
  static bool _matchesFilter(Map<String, dynamic> data, SearchFilter filter) {
    final fieldValue = data[filter.field];

    if (fieldValue == null && filter.value != null) {
      return false;
    }

    switch (filter.operator) {
      case FilterOperator.equals:
        return fieldValue == filter.value;
      case FilterOperator.contains:
        if (fieldValue is String && filter.value is String) {
          return fieldValue.toLowerCase().contains(filter.value.toString().toLowerCase());
        }
        return fieldValue.toString().contains(filter.value.toString());
      case FilterOperator.startsWith:
        if (fieldValue is String && filter.value is String) {
          return fieldValue.toLowerCase().startsWith(filter.value.toString().toLowerCase());
        }
        return fieldValue.toString().startsWith(filter.value.toString());
      case FilterOperator.greaterThan:
        return _compareValues(fieldValue, filter.value) > 0;
      case FilterOperator.lessThan:
        return _compareValues(fieldValue, filter.value) < 0;
      case FilterOperator.between:
        if (filter.value2 == null) return false;
        final comparison1 = _compareValues(fieldValue, filter.value);
        final comparison2 = _compareValues(fieldValue, filter.value2);
        return comparison1 >= 0 && comparison2 <= 0;
      case FilterOperator.inList:
        if (filter.value is List) {
          return (filter.value as List).contains(fieldValue);
        }
        return false;
    }
  }

  /// Compare two values (supports numbers, strings, dates)
  static int _compareValues(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;

    if (a is num && b is num) {
      return a.compareTo(b);
    }

    if (a is DateTime && b is DateTime) {
      return a.compareTo(b);
    }

    if (a is Timestamp && b is Timestamp) {
      return a.compareTo(b);
    }

    return a.toString().compareTo(b.toString());
  }

  /// Convert unit to map for filtering
  static Map<String, dynamic> _unitToMap(UnitModel unit) {
    return {
      'unitNumber': unit.unitNumber,
      'status': unit.status.name,
      'monthlyRate': unit.monthlyRate,
      'tenantName': unit.tenantName,
      'tenantId': unit.tenantId,
      'size': unit.size,
      'type': unit.type,
    };
  }

  /// Convert facility to map for filtering
  static Map<String, dynamic> _facilityToMap(FacilityModel facility) {
    return {
      'name': facility.name,
      'address': facility.address,
      'active': facility.active,
    };
  }

  /// Save a search filter for reuse
  static Future<String> saveSearchFilter({
    required String facilityId,
    required String name,
    String? description,
    required AdvancedSearchCriteria criteria,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final savedFilter = SavedSearchFilter(
        id: '', // Will be set by Firestore
        name: name,
        description: description,
        criteria: criteria,
        facilityId: facilityId,
        createdBy: user.uid,
        createdAt: DateTime.now(),
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('savedSearchFilters')
          .add(savedFilter.toMap());

      if (kDebugMode) {
        print('✅ [AdvancedSearch] Saved search filter: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AdvancedSearch] Error saving search filter: $e');
      }
      rethrow;
    }
  }

  /// Get saved search filters for a facility
  static Future<List<SavedSearchFilter>> getSavedSearchFilters(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('savedSearchFilters')
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => SavedSearchFilter.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AdvancedSearch] Error loading saved filters: $e');
      }
      return [];
    }
  }

  /// Delete a saved search filter
  static Future<void> deleteSavedSearchFilter({
    required String facilityId,
    required String filterId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('savedSearchFilters')
          .doc(filterId)
          .delete();

      if (kDebugMode) {
        print('✅ [AdvancedSearch] Deleted search filter: $filterId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AdvancedSearch] Error deleting search filter: $e');
      }
      rethrow;
    }
  }
}

