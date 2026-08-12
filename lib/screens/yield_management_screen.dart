import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/services/facility_stats_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class YieldManagementScreen extends ConsumerStatefulWidget {
  const YieldManagementScreen({super.key});

  @override
  ConsumerState<YieldManagementScreen> createState() => _YieldManagementScreenState();
}

class _YieldManagementScreenState extends ConsumerState<YieldManagementScreen> {
  String? _selectedFacilityId;

  @override
  void initState() {
    super.initState();
    _loadFacilities();
  }

  Future<void> _loadFacilities() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final facilities = await ref.read(userFacilitiesProvider(user.uid).future);
    if (facilities.isNotEmpty && mounted) {
      // Sync with global facility selector (same as Late Dashboard, Unit List, etc.)
      final activeId = ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
      final id = (activeId != null && facilities.any((f) => f.id == activeId))
          ? activeId
          : facilities.first.id;
      setState(() => _selectedFacilityId = id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);
    final activeId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
    final facilities = auth.whenOrNull(data: (d) => d) != null
        ? ref.watch(userFacilitiesProvider(auth.whenOrNull(data: (d) => d)!.uid)).whenOrNull(data: (d) => d)
        : null;

    // When global facility changes (top selector), sync Yield Mgmt selection
    ref.listen(activeFacilityIdProvider, (prev, next) {
      final nextId = next.whenOrNull(data: (d) => d);
      if (nextId != null &&
          facilities != null &&
          facilities.any((f) => f.id == nextId) &&
          _selectedFacilityId != nextId &&
          mounted) {
        setState(() => _selectedFacilityId = nextId);
      }
    });

    // Fallback: use active facility when _selectedFacilityId is null (e.g. after nav)
    String? effectiveId = _selectedFacilityId;
    if (effectiveId == null && facilities != null && facilities.isNotEmpty) {
      effectiveId = (activeId != null && facilities.any((f) => f.id == activeId))
          ? activeId
          : facilities.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedFacilityId != effectiveId) {
          setState(() => _selectedFacilityId = effectiveId);
        }
      });
    }

    if (effectiveId == null) {
      return _buildNoFacilityMessage();
    }

    return Column(
      children: [
        _buildFacilitySelector(effectiveId),
        Expanded(
          child: _buildYieldAnalysis(effectiveId),
        ),
      ],
    );
  }

  Widget _buildNoFacilityMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 16),
          const Text(
            'No Facilities Found',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Please create a facility to analyze yield.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilitySelector(String facilityId) {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (user) {
        if (user == null) return const SizedBox.shrink();
        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
        return facilitiesAsync.when(
          data: (facilities) {
            if (facilities.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                value: facilityId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                selectedItemBuilder: (context) => facilities
                    .map((f) => Text(
                          f.name,
                          style: AppTheme.dropdownItemTextStyle.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ))
                    .toList(),
                items: facilities.map((facility) {
                  return DropdownMenuItem(
                    value: facility.id,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        facility.name,
                        style: AppTheme.dropdownItemTextStyle,
                        softWrap: true,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedFacilityId = value);
                    ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(value);
                  }
                },
              ),
            );
          },
          loading: () => const LinearProgressIndicator(),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Future<({List<UnitModel> units, int totalUnits, int occupiedUnits})> _loadYieldData(String facilityId) async {
    final results = await Future.wait([
      UnitService.getUnitsForFacility(facilityId),
      FacilityStatsService.computeUnitCounts(facilityId),
    ]);
    final units = results[0] as List<UnitModel>;
    final counts = results[1] as ({int totalUnits, int occupiedUnits});
    return (units: units, totalUnits: counts.totalUnits, occupiedUnits: counts.occupiedUnits);
  }

  Widget _buildYieldAnalysis(String facilityId) {
    return FutureBuilder<({List<UnitModel> units, int totalUnits, int occupiedUnits})>(
      future: _loadYieldData(facilityId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, size: 64, color: AppTheme.error),
                const SizedBox(height: 16),
                Text('Error loading data: ${snapshot.error}'),
              ],
            ),
          );
        }

        final data = snapshot.data;
        final units = data?.units ?? [];
        if (units.isEmpty && (data?.totalUnits ?? 0) == 0) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.home_work, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                const Text(
                  'No Units Found',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create units to analyze yield and occupancy.',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              ],
            ),
          );
        }

        // Analyze by unit type (by-type uses units; overall uses canonical FacilityStatsService counts)
        final analysis = _analyzeUnits(units);
        final totalUnits = data!.totalUnits;
        final totalOccupied = data.occupiedUnits;
        final totalAvailable = (totalUnits - totalOccupied).clamp(0, totalUnits);
        analysis['totalUnits'] = totalUnits;
        analysis['totalOccupied'] = totalOccupied;
        analysis['totalAvailable'] = totalAvailable;
        analysis['overallOccupancy'] = totalUnits > 0 ? totalOccupied / totalUnits : 0.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildOverallStats(analysis),
              const SizedBox(height: 24),
              _buildUnitTypeAnalysis(analysis),
              const SizedBox(height: 24),
              _buildPricingRecommendations(analysis),
            ],
          ),
        );
      },
    );
  }

  Map<String, dynamic> _analyzeUnits(List<UnitModel> units) {
    final byType = <String, List<UnitModel>>{};
    for (final unit in units) {
      byType.putIfAbsent(unit.unitType, () => []).add(unit);
    }

    final typeAnalysis = <String, Map<String, dynamic>>{};
    for (final entry in byType.entries) {
      final typeUnits = entry.value;
      final occupied = typeUnits.where((u) => u.status == UnitStatus.occupied).length;
      final available = typeUnits.where((u) => u.status == UnitStatus.available).length;
      final occupancyRate = typeUnits.isEmpty ? 0.0 : occupied / typeUnits.length;
      final avgRate = typeUnits.isEmpty
          ? 0.0
          : typeUnits.map((u) => u.monthlyRate).reduce((a, b) => a + b) / typeUnits.length;

      typeAnalysis[entry.key] = {
        'total': typeUnits.length,
        'occupied': occupied,
        'available': available,
        'occupancyRate': occupancyRate,
        'avgRate': avgRate,
      };
    }

    final totalUnits = units.length;
    final totalOccupied = units.where((u) => u.status == UnitStatus.occupied).length;
    final overallOccupancy = totalUnits > 0 ? totalOccupied / totalUnits : 0.0;

    return {
      'overallOccupancy': overallOccupancy,
      'totalUnits': totalUnits,
      'totalOccupied': totalOccupied,
      'totalAvailable': totalUnits - totalOccupied,
      'byType': typeAnalysis,
    };
  }

  Widget _buildOverallStats(Map<String, dynamic> analysis) {
    final occupancy = analysis['overallOccupancy'] as double;
    final totalUnits = analysis['totalUnits'] as int;
    final occupied = analysis['totalOccupied'] as int;
    final available = analysis['totalAvailable'] as int;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.borderLight, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Overall Occupancy',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'Total Units',
                    totalUnits.toString(),
                    AppTheme.primaryBlue,
                    Icons.home_work,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    'Occupied',
                    occupied.toString(),
                    AppTheme.success,
                    Icons.check_circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    'Available',
                    available.toString(),
                    AppTheme.info,
                    Icons.circle_outlined,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    'Occupancy Rate',
                    '${(occupancy * 100).toStringAsFixed(1)}%',
                    occupancy > 0.9 ? AppTheme.success : AppTheme.warning,
                    Icons.trending_up,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildUnitTypeAnalysis(Map<String, dynamic> analysis) {
    final byType = analysis['byType'] as Map<String, dynamic>;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.borderLight, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Occupancy by Unit Type',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            ...byType.entries.map((entry) {
              final data = entry.value as Map<String, dynamic>;
              final occupancyRate = data['occupancyRate'] as double;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          entry.key,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '${(occupancyRate * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: occupancyRate > 0.9 ? AppTheme.success : AppTheme.warning,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: occupancyRate,
                      backgroundColor: AppTheme.borderLight,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        occupancyRate > 0.9 ? AppTheme.success : AppTheme.warning,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${data['occupied']} / ${data['total']} units • Avg Rate: \$${data['avgRate'].toStringAsFixed(2)}/mo',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildPricingRecommendations(Map<String, dynamic> analysis) {
    final byType = analysis['byType'] as Map<String, dynamic>;
    final recommendations = <Map<String, dynamic>>[];

    for (final entry in byType.entries) {
      final data = entry.value as Map<String, dynamic>;
      final occupancyRate = data['occupancyRate'] as double;
      final avgRate = data['avgRate'] as double;

      if (occupancyRate > 0.9 && avgRate > 0) {
        // High occupancy - suggest price increase
        final suggestedIncrease = avgRate * 0.1; // 10% increase
        recommendations.add({
          'type': entry.key,
          'action': 'increase',
          'currentRate': avgRate,
          'suggestedRate': avgRate + suggestedIncrease,
          'reason': 'High occupancy (${(occupancyRate * 100).toStringAsFixed(1)}%) - opportunity to increase rates',
        });
      } else if (occupancyRate < 0.5 && avgRate > 0) {
        // Low occupancy - suggest price decrease
        final suggestedDecrease = avgRate * 0.1; // 10% decrease
        recommendations.add({
          'type': entry.key,
          'action': 'decrease',
          'currentRate': avgRate,
          'suggestedRate': avgRate - suggestedDecrease,
          'reason': 'Low occupancy (${(occupancyRate * 100).toStringAsFixed(1)}%) - consider lowering rates to attract tenants',
        });
      }
    }

    if (recommendations.isEmpty) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppTheme.borderLight, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.check_circle, size: 48, color: AppTheme.success),
              const SizedBox(height: 16),
              const Text(
                'No Pricing Recommendations',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your occupancy rates are balanced. No immediate pricing adjustments recommended.',
                style: TextStyle(color: AppTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.borderLight, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb_outline, color: AppTheme.warning),
                const SizedBox(width: 8),
                const Text(
                  'Pricing Recommendations',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...recommendations.map((rec) {
              final isIncrease = rec['action'] == 'increase';
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                color: (isIncrease ? AppTheme.success : AppTheme.info).withOpacity(0.1),
                child: ListTile(
                  leading: Icon(
                    isIncrease ? Icons.trending_up : Icons.trending_down,
                    color: isIncrease ? AppTheme.success : AppTheme.info,
                  ),
                  title: Text(
                    '${rec['type']} Units',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(rec['reason'] as String),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            'Current: \$${rec['currentRate'].toStringAsFixed(2)}',
                            style: TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '→ Suggested: \$${rec['suggestedRate'].toStringAsFixed(2)}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isIncrease ? AppTheme.success : AppTheme.info,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
