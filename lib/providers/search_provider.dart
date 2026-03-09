import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../services/search_service.dart';
import '../services/facility_service.dart';
import '../models/facility_model.dart';

// Search service provider
final searchServiceProvider = Provider<SearchService>((ref) => SearchService());

// Search query provider
final searchQueryProvider = StateProvider<String>((ref) => '');

// Search results provider
final searchResultsProvider = FutureProvider.family<List<SearchResult>, SearchParams>((ref, params) async {
  final searchService = ref.watch(searchServiceProvider);
  final query = ref.watch(searchQueryProvider);
  
  if (query.trim().isEmpty) return [];
  
  return searchService.searchAll(
    query: query,
    ownerUid: params.ownerUid,
    facilityId: params.facilityId,
    limit: params.limit,
  );
});

// User facilities provider (stream for real-time updates)
final userFacilitiesProvider = StreamProvider.family<List<FacilityModel>, String>((ref, _) {
  return FacilityService.getFacilitiesForUserStream();
});

// Selected facility filter provider
final selectedFacilityProvider = StateProvider<FacilityModel?>((ref) => null);

// Search parameters class
class SearchParams {
  final String ownerUid;
  final String? facilityId;
  final int limit;

  SearchParams({
    required this.ownerUid,
    this.facilityId,
    this.limit = 25,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SearchParams &&
        other.ownerUid == ownerUid &&
        other.facilityId == facilityId &&
        other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(ownerUid, facilityId, limit);
}

// Search state notifier for debouncing
class SearchStateNotifier extends StateNotifier<AsyncValue<List<SearchResult>>> {
  final SearchService _searchService;
  final String _ownerUid;
  String? _facilityId;
  int _limit = 25;
  Timer? _debounceTimer;
  String _lastQuery = '';

  SearchStateNotifier(this._searchService, this._ownerUid) : super(const AsyncValue.data([]));

  void updateQuery(String query) {
    // Cancel previous debounce timer
    _debounceTimer?.cancel();
    
    if (query.trim().isEmpty) {
      state = const AsyncValue.data([]);
      _lastQuery = '';
      return;
    }

    // Skip if same query
    if (query == _lastQuery) return;
    
    state = const AsyncValue.loading();
    
    // Debounce search with 300ms delay
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (query == _lastQuery) return; // Double-check to prevent duplicate calls
      _lastQuery = query;
      _performSearch(query);
    });
  }

  void setFacilityFilter(String? facilityId) {
    _facilityId = facilityId;
    final currentQuery = (state.whenOrNull(data: (d) => d)?.isNotEmpty == true) ? 'search' : '';
    if (currentQuery.isNotEmpty) {
      _performSearch(currentQuery);
    }
  }

  void _performSearch(String query) async {
    try {
      final results = await _searchService.searchAll(
        query: query,
        ownerUid: _ownerUid,
        facilityId: _facilityId,
        limit: _limit,
      );
      state = AsyncValue.data(results);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}

// Search state provider
final searchStateProvider = StateNotifierProvider.family<SearchStateNotifier, AsyncValue<List<SearchResult>>, String>((ref, ownerUid) {
  final searchService = ref.watch(searchServiceProvider);
  return SearchStateNotifier(searchService, ownerUid);
});
