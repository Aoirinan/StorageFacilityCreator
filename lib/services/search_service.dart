import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_model.dart';
import '../models/tenant_model.dart';
import 'facility_service.dart';

class SearchResult {
  final String id;
  final String type; // 'facility', 'tenant'
  final String title;
  final String subtitle;
  final String? facilityName;
  final String? unitNumber;
  final bool isOnDNR;
  final Map<String, dynamic> data;

  SearchResult({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    this.facilityName,
    this.unitNumber,
    this.isOnDNR = false,
    required this.data,
  });
}

class SearchService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Search across all facilities and tenants owned by user
  Future<List<SearchResult>> searchAll({
    required String query,
    required String ownerUid,
    String? facilityId, // Optional: limit search to specific facility
    int limit = 25,
  }) async {
    if (query.trim().isEmpty) return [];

    final normalizedQuery = query.toLowerCase().trim();
    final results = <SearchResult>[];

    try {
      // Use parallel queries for better performance
      final futures = <Future<List<SearchResult>>>[];
      
      // Search tenants (limit to prevent large result sets)
      futures.add(_searchTenants(
        query: normalizedQuery,
        ownerUid: ownerUid,
        facilityId: facilityId,
        limit: math.min(15, limit), // Cap tenant results
      ));

      // Search facilities (if not facility-scoped)
      if (facilityId == null) {
        futures.add(_searchFacilities(
          query: normalizedQuery,
          ownerUid: ownerUid,
          limit: math.min(10, limit), // Cap facility results
        ));
      }

      // Wait for all searches in parallel (with error handling)
      final allResults = await Future.wait(
        futures.map((future) => future.catchError((error) {
          if (kDebugMode) {
            print('⚠️ Search future error: $error');
          }
          return <SearchResult>[]; // Return empty list on error
        })),
      );
      
      // Combine results
      for (final resultList in allResults) {
        results.addAll(resultList);
      }

      if (kDebugMode) {
        print('🔍 Total search results: ${results.length} (query: "$normalizedQuery")');
        final tenantCount = results.where((r) => r.type == 'tenant').length;
        final facilityCount = results.where((r) => r.type == 'facility').length;
        print('   - Tenants: $tenantCount, Facilities: $facilityCount');
      }

      // Sort by relevance (exact matches first) and limit final results
      results.sort((a, b) {
        final aExact = a.title.toLowerCase() == normalizedQuery;
        final bExact = b.title.toLowerCase() == normalizedQuery;
        if (aExact && !bExact) return -1;
        if (!aExact && bExact) return 1;
        return a.title.compareTo(b.title);
      });

      return results.take(limit).toList();
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('❌ Search error: $e');
        print('❌ Stack trace: $stackTrace');
      }
      return [];
    }
  }

  // Search tenants
  Future<List<SearchResult>> _searchTenants({
    required String query,
    required String ownerUid,
    String? facilityId,
    int limit = 25,
  }) async {
    try {
      if (kDebugMode) {
        print('🔍 Searching tenants with query: "$query", ownerUid: $ownerUid, facilityId: $facilityId');
      }

      final results = <SearchResult>[];
      Map<String, String> facilityNames = {};

      // Get facilities owned by the user first
      List<String> facilityIdsToSearch = [];
      if (facilityId != null) {
        // Search within specific facility
        facilityIdsToSearch.add(facilityId);
      } else {
        // Search across all user's facilities
        try {
          final facilitiesSnapshot = await _firestore
              .collection('facilities')
              .where('ownerUid', isEqualTo: ownerUid)
              .get();
          
          if (kDebugMode) {
            print('✅ Found ${facilitiesSnapshot.docs.length} facilities for owner');
          }

          for (final facilityDoc in facilitiesSnapshot.docs) {
            final facility = FacilityModel.fromFirestore(facilityDoc);
            facilityNames[facility.id] = facility.name;
            facilityIdsToSearch.add(facility.id);
          }
        } catch (e) {
          if (kDebugMode) {
            print('❌ Error getting facilities: $e');
          }
          return [];
        }
      }

      if (facilityIdsToSearch.isEmpty) {
        if (kDebugMode) {
          print('⚠️ No facilities found for owner');
        }
        return [];
      }

      // Get facility name if searching within a specific facility
      if (facilityId != null && facilityNames.isEmpty) {
        try {
          final facilityDoc = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .get();
          if (facilityDoc.exists) {
            final facility = FacilityModel.fromFirestore(facilityDoc);
            facilityNames[facility.id] = facility.name;
          }
        } catch (e) {
          if (kDebugMode) {
            print('Error getting facility name: $e');
          }
        }
      }

      // Search tenants in each facility
      final tenantQueries = facilityIdsToSearch.map((fid) async {
        try {
          final snapshot = await _firestore
              .collection('facilities')
              .doc(fid)
              .collection('tenants')
              .where('isActive', isEqualTo: true)
              .limit(limit * 2) // Get more to filter
              .get();

          if (kDebugMode) {
            print('📋 Found ${snapshot.docs.length} tenants in facility $fid');
          }

          final facilityTenants = <SearchResult>[];
          for (final doc in snapshot.docs) {
            try {
              final tenant = TenantModel.fromFirestore(doc);
              
              // Get facility name for context
              final facilityName = facilityNames[fid] ?? 'Unknown Facility';

              // Check if tenant matches search criteria
              if (_tenantMatchesQuery(tenant, query)) {
                facilityTenants.add(SearchResult(
                  id: tenant.id,
                  type: 'tenant',
                  title: tenant.name,
                  subtitle: 'Unit ${tenant.unitNumber} • ${tenant.email}',
                  facilityName: facilityName,
                  unitNumber: tenant.unitNumber,
                  isOnDNR: tenant.isOnDNR,
                  data: {
                    ...tenant.toFirestore(),
                    'facilityId': fid, // Ensure facilityId is in data
                  },
                ));
              }
            } catch (e) {
              if (kDebugMode) {
                print('⚠️ Error processing tenant ${doc.id}: $e');
              }
              continue;
            }
          }
          return facilityTenants;
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Error searching tenants in facility $fid: $e');
          }
          return <SearchResult>[];
        }
      });

      // Wait for all facility searches to complete
      final allFacilityResults = await Future.wait(tenantQueries);
      
      // Combine all results
      for (final facilityResults in allFacilityResults) {
        results.addAll(facilityResults);
      }

      if (kDebugMode) {
        print('✅ Found ${results.length} matching tenants');
      }

      return results.take(limit).toList();
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('❌ Tenant search error: $e');
        print('Stack trace: $stackTrace');
      }
      return [];
    }
  }

  // Search facilities
  Future<List<SearchResult>> _searchFacilities({
    required String query,
    required String ownerUid,
    int limit = 25,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .where('ownerUid', isEqualTo: ownerUid)
          .limit(limit * 2)
          .get();

      final results = <SearchResult>[];

      for (final doc in snapshot.docs) {
        final facility = FacilityModel.fromFirestore(doc);
        
        // Check if facility matches search criteria
        if (_facilityMatchesQuery(facility, query)) {
          results.add(SearchResult(
            id: facility.id,
            type: 'facility',
            title: facility.name,
            subtitle: '${facility.occupiedUnits}/${facility.totalUnits} units occupied',
            facilityName: facility.name,
            isOnDNR: false,
            data: facility.toFirestore(),
          ));
        }
      }

      return results.take(limit).toList();
    } catch (e) {
      if (kDebugMode) {
        print('Facility search error: $e');
      }
      return [];
    }
  }

  // Check if tenant matches search query
  bool _tenantMatchesQuery(TenantModel tenant, String query) {
    final normalizedQuery = query.toLowerCase().trim();
    if (normalizedQuery.isEmpty) return false;
    
    // Name match (case-insensitive contains)
    if (tenant.nameLower.contains(normalizedQuery)) return true;
    
    // Unit number match (contains - more flexible)
    final unitLower = tenant.unitNumber.toLowerCase().trim();
    if (unitLower.contains(normalizedQuery)) return true;
    
    // Email match (case-insensitive contains)
    if (tenant.emailLower.contains(normalizedQuery)) return true;
    
    // Phone match (digits only, contains)
    final phoneDigits = tenant.phoneDigits;
    if (phoneDigits.contains(normalizedQuery.replaceAll(RegExp(r'[^\d]'), ''))) return true;
    
    return false;
  }

  // Check if facility matches search query
  bool _facilityMatchesQuery(FacilityModel facility, String query) {
    final normalizedQuery = query.toLowerCase();
    
    // Name match (case-insensitive prefix)
    if (facility.name.toLowerCase().startsWith(normalizedQuery)) return true;
    
    // Address match (case-insensitive prefix)
    if (facility.address?.toLowerCase().startsWith(normalizedQuery) == true) return true;
    
    return false;
  }

  // Get user's facilities for dropdown
  Future<List<FacilityModel>> getUserFacilities(String ownerUid) async {
    try {
      if (kDebugMode) {
        print('🔄 Attempting to get facilities for owner: $ownerUid');
      }
      
      // Use the facility service which handles owner-scoped queries
      final facilities = await FacilityService.getUserFacilities();
      
      if (kDebugMode) {
        print('✅ Successfully retrieved ${facilities.length} facilities');
      }

      return facilities;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting user facilities: $e');
        print('🔍 Error type: ${e.runtimeType}');
        if (e.toString().contains('permission-denied')) {
          print('🚨 PERMISSION DENIED: Check Firestore security rules for facilities collection');
        } else if (e.toString().contains('failed-precondition') && e.toString().contains('index')) {
          print('📋 INDEX BUILDING: Firestore indexes are being created. Using fallback...');
        }
      }
      
      // Return empty list if there's an error
      return [];
    }
  }
}

