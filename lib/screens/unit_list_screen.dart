import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/unit_model.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';
import '../providers/unit_provider.dart';
import '../providers/tenant_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/active_facility_provider.dart';
import '../services/facility_service.dart';
import '../services/facility_stats_service.dart';
import '../services/unit_service.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

/// Unit List Screen - Table/List view of all units for selected facility
class UnitListScreen extends ConsumerStatefulWidget {
  const UnitListScreen({super.key});

  @override
  ConsumerState<UnitListScreen> createState() => _UnitListScreenState();
}

class _UnitListScreenState extends ConsumerState<UnitListScreen> {
  String? _selectedFacilityId;
  String _searchQuery = '';
  Set<UnitStatus> _statusFilters = UnitStatus.values.toSet();
  final Set<String> _selectedUnitIds = {};

  @override
  void initState() {
    super.initState();
    _loadFacilities();
  }

  Future<void> _loadFacilities() async {
    final facilities = await FacilityService.getUserFacilities();
    if (facilities.isNotEmpty && mounted) {
      final activeId =
          ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
      final id = (activeId != null && facilities.any((f) => f.id == activeId))
          ? activeId
          : facilities.first.id;
      setState(() => _selectedFacilityId = id);
    }
  }

  /// Total capacity = facility.totalUnits; occupied = canonical count. Used for Unit List denominator.
  Future<({int totalCapacity, int occupied})> _getUnitCountsForFacility(
    String facilityId,
    int fallbackTotal,
    int fallbackOccupied,
  ) async {
    try {
      final counts = await FacilityStatsService.computeUnitCounts(facilityId);
      return (totalCapacity: counts.totalUnits, occupied: counts.occupiedUnits);
    } catch (_) {
      return (totalCapacity: fallbackTotal, occupied: fallbackOccupied);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<String?>>(activeFacilityIdProvider, (prev, next) {
      if (!mounted) return;
      final user = ref.read(authStateProvider).maybeWhen(
            data: (u) => u,
            orElse: () => null,
          );
      if (user == null) return;
      final facilities = ref.read(userFacilitiesProvider(user.uid)).maybeWhen(
            data: (f) => f,
            orElse: () => null,
          );
      if (facilities == null || facilities.isEmpty) return;
      final nextId = next.whenOrNull(data: (d) => d);
      if (nextId != null &&
          facilities.any((f) => f.id == nextId) &&
          _selectedFacilityId != nextId) {
        setState(() {
          _selectedFacilityId = nextId;
          _selectedUnitIds.clear();
        });
      }
    });

    if (_selectedFacilityId == null) {
      return _buildNoFacilityMessage();
    }

    return Column(
      children: [
        _buildFacilitySelector(),
        _buildToolbar(),
        Expanded(
          child: _buildUnitsList(),
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
            'Please create a facility to manage units.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilitySelector() {
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
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _selectedFacilityId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Facility',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.business),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                      ),
                      selectedItemBuilder: (context) {
                        final colorScheme = Theme.of(context).colorScheme;
                        return facilities
                            .map((f) => Text(
                                  f.name,
                                  style: AppTheme.dropdownItemTextStyle
                                      .copyWith(color: colorScheme.onSurface),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ))
                            .toList();
                      },
                      items: facilities.map((facility) {
                        return DropdownMenuItem(
                          value: facility.id,
                          child: Text(
                            facility.name,
                            style: AppTheme.dropdownItemTextStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _selectedFacilityId = value;
                            _selectedUnitIds.clear();
                          });
                          ref
                              .read(activeFacilityIdProvider.notifier)
                              .setActiveFacilityId(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (_selectedFacilityId != null) {
                        final facilityId = _selectedFacilityId!;
                        ref
                            .read(activeFacilityIdProvider.notifier)
                            .setActiveFacilityId(facilityId);
                        context.push(
                          '${AppRoute.unitsMap}?facilityId=${Uri.encodeComponent(facilityId)}',
                        );
                      }
                    },
                    icon: const Icon(Icons.map),
                    label: const Text('Open Map Editor'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
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

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search units...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.toLowerCase();
                });
              },
            ),
          ),
          const SizedBox(width: 16),
          PopupMenuButton<UnitStatus>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter by Status',
            onSelected: (status) {
              setState(() {
                if (_statusFilters.contains(status)) {
                  _statusFilters.remove(status);
                } else {
                  _statusFilters.add(status);
                }
              });
            },
            itemBuilder: (context) => UnitStatus.values.map((status) {
              final isSelected = _statusFilters.contains(status);
              return PopupMenuItem(
                value: status,
                child: Row(
                  children: [
                    Icon(
                      isSelected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      color: isSelected
                          ? AppTheme.primaryBlue
                          : AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(status.name),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _selectedUnitIds.clear();
              });
            },
            icon: const Icon(Icons.deselect, size: 18),
            label: const Text('Clear selection'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () {
              if (_selectedFacilityId != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Unit creation is available via Map Editor'),
                    backgroundColor: AppTheme.info,
                  ),
                );
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('New Unit'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionBar(int selectedCount, List<UnitModel> filteredUnits,
      Map<String, TenantModel> tenantMap) {
    if (selectedCount == 0) return const SizedBox.shrink();
    final canDeleteIds = filteredUnits
        .where((u) => _selectedUnitIds.contains(u.id))
        .where((u) =>
            u.tenantId == null ||
            u.tenantId!.isEmpty ||
            !tenantMap.containsKey(u.tenantId))
        .map((u) => u.id)
        .toList();
    final skipCount = selectedCount - canDeleteIds.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Text(
            '$selectedCount selected',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: () => setState(() => _selectedUnitIds.clear()),
            icon: const Icon(Icons.close, size: 18),
            label: const Text('Clear selection'),
          ),
          const SizedBox(width: 8),
          if (canDeleteIds.isNotEmpty) ...[
            FilledButton.icon(
              onPressed: () =>
                  _handleBulkDelete(canDeleteIds, skipCount, filteredUnits),
              icon: const Icon(Icons.archive_outlined, size: 18),
              label: Text(skipCount > 0
                  ? 'Archive ${canDeleteIds.length} (${skipCount} have tenants)'
                  : 'Archive ${canDeleteIds.length}'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  _handleBulkPermanentDelete(canDeleteIds, skipCount),
              icon: const Icon(Icons.delete_forever, size: 18),
              label: Text('Delete ${canDeleteIds.length} permanently'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.error,
                side: const BorderSide(color: AppTheme.error),
              ),
            ),
          ] else
            Text(
              'Selected units have tenants; remove tenants first to archive.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
        ],
      ),
    );
  }

  Widget _buildUnitsList() {
    if (_selectedFacilityId == null) {
      return const Center(child: Text('Select a facility'));
    }

    final unitsAsync = ref.watch(facilityUnitsProvider(_selectedFacilityId!));
    final tenantsAsync =
        ref.watch(facilityTenantsProvider(_selectedFacilityId!));

    return unitsAsync.when(
      data: (units) {
        final tenants =
            tenantsAsync.whenOrNull(data: (d) => d) ?? <TenantModel>[];
        final tenantMap = {for (final t in tenants) t.id: t};
        bool isGhostUnit(unit) =>
            unit.tenantId != null &&
            unit.tenantId!.isNotEmpty &&
            !tenantMap.containsKey(unit.tenantId);
        String tenantDisplayName(unit) {
          if (unit.tenantId == null) return unit.tenantName ?? '—';
          final t = tenantMap[unit.tenantId];
          return t?.name ?? unit.tenantName ?? '—';
        }

        final unitsWithoutGhosts = units.where((u) => !isGhostUnit(u)).toList();
        final filteredUnits = unitsWithoutGhosts.where((unit) {
          if (!_statusFilters.contains(unit.status)) return false;
          if (_searchQuery.isNotEmpty) {
            return unit.unitNumber.toLowerCase().contains(_searchQuery) ||
                (tenantDisplayName(unit).toLowerCase().contains(_searchQuery));
          }
          return true;
        }).toList();

        if (filteredUnits.isEmpty) {
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
                  _searchQuery.isEmpty
                      ? 'Create your first unit to get started'
                      : 'No units match your search',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              ],
            ),
          );
        }

        final tenantIds = tenantMap.keys.toSet();
        final occupiedCount = filteredUnits
            .where(
              (u) =>
                  u.status == UnitStatus.occupied &&
                  u.tenantId != null &&
                  tenantIds.contains(u.tenantId),
            )
            .length;
        final selectedCountInFiltered =
            filteredUnits.where((u) => _selectedUnitIds.contains(u.id)).length;
        final allFilteredSelected = filteredUnits.isEmpty
            ? false
            : selectedCountInFiltered == filteredUnits.length;
        final someSelected = selectedCountInFiltered > 0;
        final selectAllValue =
            allFilteredSelected ? true : (someSelected ? null : false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              clipBehavior: Clip.hardEdge,
              child: _buildSelectionBar(
                  _selectedUnitIds.length, filteredUnits, tenantMap),
            ),
            FutureBuilder<({int totalCapacity, int occupied})>(
              future: _getUnitCountsForFacility(_selectedFacilityId!,
                  unitsWithoutGhosts.length, occupiedCount),
              builder: (context, snap) {
                final total =
                    snap.data?.totalCapacity ?? unitsWithoutGhosts.length;
                final occupied = snap.data?.occupied ?? occupiedCount;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '$occupied / $total units',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              },
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(
                        Theme.of(context).colorScheme.surfaceContainerHighest),
                    columns: [
                      DataColumn(
                        label: Checkbox(
                          value: selectAllValue,
                          tristate: true,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                for (final u in filteredUnits) {
                                  _selectedUnitIds.add(u.id);
                                }
                              } else {
                                for (final u in filteredUnits) {
                                  _selectedUnitIds.remove(u.id);
                                }
                              }
                            });
                          },
                        ),
                      ),
                      const DataColumn(
                          label: Text('Unit #',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      const DataColumn(
                          label: Text('Type',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      const DataColumn(
                          label: Text('Status',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      const DataColumn(
                          label: Text('Tenant',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      const DataColumn(
                          label: Text('Monthly Rate',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      const DataColumn(
                          label: Text('Size',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      const DataColumn(
                          label: Text('Actions',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                    ],
                    rows: filteredUnits
                        .map((unit) => _buildUnitRow(unit, tenantMap))
                        .toList(),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text('Error loading units'),
            const SizedBox(height: 8),
            Text('$error', style: TextStyle(color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  DataRow _buildUnitRow(UnitModel unit, Map<String, TenantModel> tenantMap) {
    final tenantName = unit.tenantId != null
        ? (tenantMap[unit.tenantId]?.name ?? unit.tenantName ?? '—')
        : (unit.tenantName ?? '—');
    final isSelected = _selectedUnitIds.contains(unit.id);
    return DataRow(
      cells: [
        DataCell(
          Checkbox(
            value: isSelected,
            onChanged: (value) {
              setState(() {
                if (value == true) {
                  _selectedUnitIds.add(unit.id);
                } else {
                  _selectedUnitIds.remove(unit.id);
                }
              });
            },
          ),
        ),
        DataCell(
          Text(
            unit.unitNumber,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        DataCell(Text(unit.unitType)),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildStatusChip(unit.status),
              if (unit.isOverlocked) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppTheme.error),
                  ),
                  child: const Text('OVERLOCKED',
                      style: TextStyle(
                          color: AppTheme.error,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ],
          ),
        ),
        DataCell(Text(tenantName)),
        DataCell(Text('\$${unit.monthlyRate.toStringAsFixed(2)}')),
        DataCell(
          Text(
            unit.dimensions != null
                ? '${unit.dimensions!['width']}x${unit.dimensions!['depth']}'
                : '-',
          ),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.visibility, size: 18),
                tooltip: 'View Details',
                onPressed: () {
                  context.push(
                      '${AppRoute.unitDetail}?unitId=${unit.id}&facilityId=${unit.facilityId}');
                },
              ),
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
                tooltip: 'Edit Unit',
                onPressed: () {
                  context.push(AppRoute.unitEdit, extra: unit);
                },
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                tooltip: 'Archive or Delete',
                onSelected: (value) {
                  if (value == 'archive') {
                    _handleArchiveUnit(unit, tenantMap);
                  } else if (value == 'delete') {
                    _handlePermanentDeleteUnit(unit, tenantMap);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'archive',
                    child: ListTile(
                      leading: Icon(Icons.archive_outlined, size: 20),
                      title: Text('Archive'),
                      subtitle: Text('Hide from list; can be restored'),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_forever,
                          size: 20, color: AppTheme.error),
                      title: const Text('Delete permanently'),
                      subtitle:
                          const Text('Remove from database; cannot be undone'),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleBulkDelete(
    List<String> unitIds,
    int skippedCount,
    List<UnitModel> filteredUnits,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive selected units'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Archive ${unitIds.length} unit(s)?'),
            const SizedBox(height: 8),
            const Text(
              'Units will be hidden from the default list. You can restore them later if needed.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            if (skippedCount > 0) ...[
              const SizedBox(height: 12),
              Text(
                '$skippedCount selected unit(s) have tenants and were not included.',
                style: TextStyle(fontSize: 13, color: AppTheme.warning),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final notifier = ref.read(unitOperationsProvider.notifier);
      for (final id in unitIds) {
        await notifier.archiveUnit(_selectedFacilityId!, id);
      }
      if (mounted) {
        setState(() {
          for (final id in unitIds) {
            _selectedUnitIds.remove(id);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${unitIds.length} unit(s) archived'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error archiving units: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _handleBulkPermanentDelete(
      List<String> unitIds, int skippedCount) async {
    final acknowledged = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Before you permanently delete'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You are about to permanently delete ${unitIds.length} unit(s).',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber, color: AppTheme.error, size: 22),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This cannot be undone. Those unit records are removed from this facility everywhere they appear—the unit list, map editor, occupancy, and other workflows that depend on that unit.',
                            style: TextStyle(
                                fontSize: 13, color: AppTheme.textPrimary),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Tenant customer profiles are not deleted by this action, but anything that still pointed at these units (history, notes, or mismatched data) can become inconsistent or harder to interpret.',
                      style:
                          TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    ),
                  ],
                ),
              ),
              if (skippedCount > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '$skippedCount selected unit(s) have tenants and were not included.',
                  style: TextStyle(fontSize: 13, color: AppTheme.warning),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (acknowledged != true || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Confirm permanent deletion'),
        content: Text(
          'Permanently delete ${unitIds.length} unit(s) now? You will not be able to restore them.',
          style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _selectedFacilityId == null) return;
    try {
      final notifier = ref.read(unitOperationsProvider.notifier);
      for (final id in unitIds) {
        await notifier.deleteUnit(_selectedFacilityId!, id);
      }
      if (mounted) {
        setState(() {
          for (final id in unitIds) {
            _selectedUnitIds.remove(id);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${unitIds.length} unit(s) deleted permanently'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting units: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _handleArchiveUnit(
      UnitModel unit, Map<String, TenantModel> tenantMap) async {
    final hasActiveTenant = unit.tenantId != null &&
        unit.tenantId!.isNotEmpty &&
        tenantMap.containsKey(unit.tenantId);

    final shouldArchive = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive Unit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasActiveTenant) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.warning),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: AppTheme.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This unit has an active tenant (${tenantMap[unit.tenantId]?.name}). Cannot archive.',
                        style: TextStyle(color: AppTheme.warning),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                  'Please remove the tenant first before archiving this unit.'),
            ] else ...[
              Text('Archive unit ${unit.unitNumber}?'),
              const SizedBox(height: 12),
              const Text(
                'This will hide the unit from the default list. You can restore it later if needed.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          if (!hasActiveTenant)
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Archive'),
            ),
        ],
      ),
    );

    if (shouldArchive == true) {
      try {
        await ref.read(unitOperationsProvider.notifier).archiveUnit(
              _selectedFacilityId!,
              unit.id,
            );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Unit ${unit.unitNumber} archived successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error archiving unit: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _handlePermanentDeleteUnit(
      UnitModel unit, Map<String, TenantModel> tenantMap) async {
    final hasActiveTenant = unit.tenantId != null &&
        unit.tenantId!.isNotEmpty &&
        tenantMap.containsKey(unit.tenantId);

    if (hasActiveTenant) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Unit ${unit.unitNumber} has an active tenant. Remove the tenant first to delete the unit.',
            ),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    final acknowledged = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Before you permanently delete'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You are about to permanently delete unit ${unit.unitNumber}.',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber, color: AppTheme.error, size: 22),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This cannot be undone. The unit record is removed from this facility everywhere it appears—the unit list, map editor, occupancy, and other workflows that depend on that unit.',
                            style: TextStyle(
                                fontSize: 13, color: AppTheme.textPrimary),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Tenant customer profiles are not deleted by this action, but anything that still pointed at this unit can become inconsistent or harder to interpret.',
                      style:
                          TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (acknowledged != true || !mounted) return;

    final shouldDelete = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Confirm permanent deletion'),
        content: Text(
          'Permanently delete unit ${unit.unitNumber} now? You will not be able to restore it.',
          style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      try {
        await ref.read(unitOperationsProvider.notifier).deleteUnit(
              _selectedFacilityId!,
              unit.id,
            );
        if (mounted) {
          setState(() => _selectedUnitIds.remove(unit.id));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Unit ${unit.unitNumber} deleted'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting unit: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Widget _buildStatusChip(UnitStatus status) {
    Color color;
    switch (status) {
      case UnitStatus.available:
        color = AppTheme.success;
        break;
      case UnitStatus.occupied:
        color = AppTheme.primaryBlue;
        break;
      case UnitStatus.reserved:
        color = AppTheme.warning;
        break;
      case UnitStatus.maintenance:
        color = AppTheme.error;
        break;
      default:
        color = AppTheme.textSecondary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Text(
        status.name,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
