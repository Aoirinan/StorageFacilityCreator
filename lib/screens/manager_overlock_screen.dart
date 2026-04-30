import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/unit_model.dart';
import '../models/tenant_model.dart';
import '../models/overlock_model.dart';
import '../models/facility_model.dart';
import '../models/permission_model.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/unit_provider.dart';
import '../providers/tenant_provider.dart';
import '../services/overlock_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../utils/print_util.dart';
import '../widgets/permission_gate.dart';

/// Manager Overlock: view units, mark overlocked, bulk actions, print list.
/// Role-restricted to manager/admin.
class ManagerOverlockScreen extends ConsumerStatefulWidget {
  const ManagerOverlockScreen({super.key});

  @override
  ConsumerState<ManagerOverlockScreen> createState() => _ManagerOverlockScreenState();
}

const _kAllFacilitiesOverlock = '__all__';

class _ManagerOverlockScreenState extends ConsumerState<ManagerOverlockScreen> {
  String? _facilityId;
  String _searchQuery = '';
  String _statusFilter = 'all'; // all | overlocked | not_overlocked
  String _delinquencyFilter = 'all'; // all | delinquent | not_delinquent
  final Set<String> _selectedUnitIds = {};
  bool _loading = false;
  String? _confirmNote;
  String _clearConfirmToken = '';
  bool _selectModeMobile = false; // xs: toggle checkboxes on cards
  bool _filtersSheetOpen = false; // xs: filters in bottom sheet

  bool get _isAllFacilities => _facilityId == _kAllFacilitiesOverlock;

  @override
  Widget build(BuildContext context) {
    // AppShell already provides sidebar + top bar; do not use ModernPageWrapper here.
    return PermissionGate(
      permission: PermissionType.manageOverlock,
      hideIfDenied: false,
      fallback: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'You need manager or admin access to use Manager Overlock.',
            style: TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
      ),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (user) {
        if (user == null) return const Center(child: Text('Please sign in'));
        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
        return facilitiesAsync.when(
          data: (facilities) {
            if (facilities.isEmpty) {
              return const Center(child: Text('No facilities found'));
            }
            _facilityId ??= _kAllFacilitiesOverlock;
            final width = MediaQuery.of(context).size.width;
            final isPhone = Breakpoints.isPhone(width);
            final isDesktop = Breakpoints.isDesktop(width);
            final useTable = Breakpoints.useTableLayout(width);

            return LayoutBuilder(
              builder: (context, constraints) {
                final maxHeight = constraints.maxHeight;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Title row - compact
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        isPhone ? 16 : 24,
                        isPhone ? 8 : 12,
                        isPhone ? 16 : 24,
                        0,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Manager Overlock',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          if (isPhone && !_isAllFacilities) ...[
                            TextButton.icon(
                              icon: Icon(_selectModeMobile ? Icons.done : Icons.checklist),
                              label: Text(_selectModeMobile ? 'Done' : 'Select'),
                              onPressed: () => setState(() {
                                _selectModeMobile = !_selectModeMobile;
                                if (!_selectModeMobile) _selectedUnitIds.clear();
                              }),
                            ),
                            IconButton(
                              icon: const Icon(Icons.filter_list),
                              onPressed: () => _showFiltersBottomSheet(context, facilities),
                              tooltip: 'Filters',
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Filters: inline on sm/md/lg, in sheet on xs
                    if (!isPhone) _buildFiltersSection(context, width, facilities),
                    if (_selectedUnitIds.isNotEmpty && !isPhone && !_isAllFacilities) _buildBulkBar(context, width),
                    // Data area: fills remaining height; only this scrolls on desktop
                    Expanded(
                      child: useTable
                          ? _buildTableOrScrollableData(context, width, facilities)
                          : _buildCardList(context, width, facilities),
                    ),
                    // Mobile: bottom bulk action bar when selection not empty
                    if (isPhone && _selectedUnitIds.isNotEmpty && !_isAllFacilities) _buildMobileBulkBar(context),
                  ],
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }

  void _showFiltersBottomSheet(BuildContext context, List<FacilityModel> facilities) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewPadding.bottom),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Filters', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              _buildFilterFieldsColumn(ctx, facilities),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    ).then((_) => setState(() => _filtersSheetOpen = false));
  }

  static const double _filterMinWidth = 140;
  static const double _filterMaxWidth = 260;

  Widget _buildFiltersSection(BuildContext context, double width, List<FacilityModel> facilities) {
    final cols = Breakpoints.filterColumns(width);
    final isTight = Breakpoints.isTablet(width);
    final padding = isTight ? 16.0 : 24.0;
    final itemWidth = cols >= 2
        ? ((width - padding * 2) / 2).clamp(_filterMinWidth, _filterMaxWidth)
        : (width - padding * 2).clamp(_filterMinWidth, _filterMaxWidth);
    final deco = const InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
    Widget wrapChild(Widget w) => SizedBox(width: cols == 1 ? null : itemWidth, child: w);
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: padding, vertical: isTight ? 6 : 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          wrapChild(DropdownButtonFormField<String>(
            value: _facilityId ?? _kAllFacilitiesOverlock,
            isExpanded: true,
            decoration: deco.copyWith(labelText: 'Facility'),
            selectedItemBuilder: (context) => [
              Text('All Facilities',
                  style: AppTheme.dropdownItemTextStyle.copyWith(
                      color: Theme.of(context).colorScheme.onSurface),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1),
              ...facilities.map((f) => Text(f.name,
                  style: AppTheme.dropdownItemTextStyle.copyWith(
                      color: Theme.of(context).colorScheme.onSurface),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1)),
            ],
            items: [
              const DropdownMenuItem(value: _kAllFacilitiesOverlock, child: Text('All Facilities')),
              ...facilities.map((f) => DropdownMenuItem(value: f.id, child: Text(f.name))),
            ],
            onChanged: (v) => setState(() {
              _facilityId = v;
              _selectedUnitIds.clear();
            }),
          )),
          wrapChild(TextField(
            decoration: deco.copyWith(hintText: 'Search name, unit #, phone, email', prefixIcon: const Icon(Icons.search, size: 20)),
            onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
          )),
          wrapChild(DropdownButtonFormField<String>(
            value: _statusFilter,
            decoration: deco.copyWith(labelText: 'Overlock'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: 'overlocked', child: Text('Overlocked')),
              DropdownMenuItem(value: 'not_overlocked', child: Text('Not Overlocked')),
            ],
            onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
          )),
          wrapChild(DropdownButtonFormField<String>(
            value: _delinquencyFilter,
            decoration: deco.copyWith(labelText: 'Delinquency'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: 'delinquent', child: Text('Delinquent Only')),
              DropdownMenuItem(value: 'not_delinquent', child: Text('Not Delinquent')),
            ],
            onChanged: (v) => setState(() => _delinquencyFilter = v ?? 'all'),
          )),
        ],
      ),
    );
  }

  Widget _buildFilterFieldsColumn(BuildContext context, List<FacilityModel> facilities) {
    final deco = const InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          value: _facilityId ?? _kAllFacilitiesOverlock,
          isExpanded: true,
          decoration: deco.copyWith(labelText: 'Facility'),
          selectedItemBuilder: (context) => [
            Text('All Facilities',
                style: AppTheme.dropdownItemTextStyle.copyWith(
                    color: Theme.of(context).colorScheme.onSurface),
                overflow: TextOverflow.ellipsis,
                maxLines: 1),
            ...facilities.map((f) => Text(f.name,
                style: AppTheme.dropdownItemTextStyle.copyWith(
                    color: Theme.of(context).colorScheme.onSurface),
                overflow: TextOverflow.ellipsis,
                maxLines: 1)),
          ],
          items: [
            const DropdownMenuItem(value: _kAllFacilitiesOverlock, child: Text('All Facilities')),
            ...facilities.map((f) => DropdownMenuItem(value: f.id, child: Text(f.name))),
          ],
          onChanged: (v) => setState(() {
            _facilityId = v;
            _selectedUnitIds.clear();
          }),
        ),
        const SizedBox(height: 8),
        TextField(
          decoration: deco.copyWith(hintText: 'Search name, unit #, phone, email', prefixIcon: const Icon(Icons.search, size: 20)),
          onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _statusFilter,
          decoration: deco.copyWith(labelText: 'Overlock'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All')),
            DropdownMenuItem(value: 'overlocked', child: Text('Overlocked')),
            DropdownMenuItem(value: 'not_overlocked', child: Text('Not Overlocked')),
          ],
          onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _delinquencyFilter,
          decoration: deco.copyWith(labelText: 'Delinquency'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All')),
            DropdownMenuItem(value: 'delinquent', child: Text('Delinquent Only')),
            DropdownMenuItem(value: 'not_delinquent', child: Text('Not Delinquent')),
          ],
          onChanged: (v) => setState(() => _delinquencyFilter = v ?? 'all'),
        ),
      ],
    );
  }

  Widget _buildBulkBar(BuildContext context, double width) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppTheme.primaryBlue.withOpacity(0.08),
      child: Row(
        children: [
          Text(
            '${_selectedUnitIds.length} selected',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: _loading ? null : () => _bulkOverlock(true),
            icon: const Icon(Icons.lock, size: 18),
            label: const Text('Overlock Selected'),
          ),
          TextButton.icon(
            onPressed: _loading ? null : () => _bulkOverlock(false),
            icon: const Icon(Icons.lock_open, size: 18),
            label: const Text('Remove Overlock Selected'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _loading ? null : _overlockAllDelinquent,
            icon: const Icon(Icons.warning_amber, size: 18),
            label: const Text('Overlock All Delinquent'),
          ),
          TextButton.icon(
            onPressed: _loading ? null : _clearOverlockAll,
            icon: const Icon(Icons.clear_all, size: 18),
            label: const Text('Clear Overlock All (Filtered)'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _loading ? null : _printOverlockList,
            icon: const Icon(Icons.print, size: 18),
            label: const Text('Print Overlock List'),
          ),
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => setState(() => _selectedUnitIds.clear()),
            tooltip: 'Clear selection',
          ),
        ],
      ),
    );
  }

  /// Resolves units, tenantMap, and balances for the current facility selection.
  /// Returns null while loading, or a record with the merged data.
  ({List<UnitModel> units, Map<String, TenantModel> tenantMap, Map<String, double> balances})?
      _resolveData(List<FacilityModel> facilities) {
    if (_isAllFacilities) {
      final allUnits = <UnitModel>[];
      final allTenants = <TenantModel>[];
      final allBalances = <String, double>{};
      for (final f in facilities) {
        final u = ref.watch(facilityUnitsProvider(f.id));
        final t = ref.watch(facilityTenantsProvider(f.id));
        final b = ref.watch(facilityBalancesProvider(f.id));
        if (u is AsyncLoading || t is AsyncLoading) return null;
        allUnits.addAll(u.whenOrNull(data: (d) => d) ?? []);
        allTenants.addAll(t.whenOrNull(data: (d) => d) ?? []);
        allBalances.addAll(b.whenOrNull(data: (d) => d) ?? {});
      }
      return (
        units: allUnits,
        tenantMap: {for (final t in allTenants) t.id: t},
        balances: allBalances,
      );
    } else {
      if (_facilityId == null) return null;
      final u = ref.watch(facilityUnitsProvider(_facilityId!));
      final t = ref.watch(facilityTenantsProvider(_facilityId!));
      final b = ref.watch(facilityBalancesProvider(_facilityId!));
      if (u is AsyncLoading || t is AsyncLoading) return null;
      final units = u.whenOrNull(data: (d) => d) ?? <UnitModel>[];
      final tenants = t.whenOrNull(data: (d) => d) ?? <TenantModel>[];
      final balances = b.whenOrNull(data: (d) => d) ?? <String, double>{};
      return (
        units: units,
        tenantMap: {for (final t in tenants) t.id: t},
        balances: balances,
      );
    }
  }

  Widget _buildTable() {
    if (_facilityId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // Need facilities list for _resolveData in all-facilities mode
    final authState = ref.watch(authStateProvider);
    final user = authState.whenOrNull(data: (u) => u);
    if (user == null) return const Center(child: CircularProgressIndicator());
    final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
    final facilities = facilitiesAsync.whenOrNull(data: (d) => d) ?? <FacilityModel>[];
    final resolved = _resolveData(facilities);
    if (resolved == null) return const Center(child: CircularProgressIndicator());
    final units = resolved.units;
    final tenantMap = resolved.tenantMap;
    final balances = resolved.balances;
    final rows = _filterUnits(units, tenantMap, balances);
    if (rows.isEmpty) {
      return const Center(child: Text('No units match filters'));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(Theme.of(context).colorScheme.surfaceContainerHighest),
          columns: const [
            DataColumn(label: Text('', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Unit #', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Tenant', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Phone / Email', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Balance', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Overlock', style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(label: Text('Actions', style: TextStyle(fontWeight: FontWeight.bold))),
          ],
          rows: rows.map((unit) => _buildRow(unit, tenantMap, balances)).toList(),
        ),
      ),
    );
  }

  /// Desktop: only the table body scrolls; header is sticky.
  Widget _buildTableOrScrollableData(BuildContext context, double width, List<FacilityModel> facilities) {
    if (_facilityId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final resolved = _resolveData(facilities);
    if (resolved == null) return const Center(child: CircularProgressIndicator());
    final units = resolved.units;
    final tenantMap = resolved.tenantMap;
    final balances = resolved.balances;
        final rows = _filterUnits(units, tenantMap, balances);
        if (rows.isEmpty) {
          return const Center(child: Text('No units match filters'));
        }
        const rowHeight = 40.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Ink(
                child: Row(
                  children: [
                    const SizedBox(width: 44, child: Center(child: Icon(Icons.check_box_outlined, size: 20))),
                    Expanded(flex: 1, child: Text('Unit #', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold))),
                    Expanded(flex: 2, child: Text('Tenant', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold))),
                    Expanded(flex: 2, child: Text('Phone / Email', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold))),
                    Expanded(flex: 1, child: Text('Balance', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold))),
                    Expanded(flex: 1, child: Text('Overlock', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold))),
                    const Expanded(flex: 2, child: SizedBox()),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: AppTheme.borderLight),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final unit = rows[index];
                  return _buildScrollableTableRow(context, unit, tenantMap, balances, rowHeight);
                },
              ),
            ),
          ],
        );
  }

  Widget _buildScrollableTableRow(
    BuildContext context,
    UnitModel unit,
    Map<String, TenantModel> tenantMap,
    Map<String, double> balances,
    double rowHeight,
  ) {
    final tenant = unit.tenantId != null ? tenantMap[unit.tenantId] : null;
    final balance = unit.tenantId != null ? (balances[unit.tenantId] ?? 0) : 0.0;
    final isSelected = _selectedUnitIds.contains(unit.id);
    return Material(
      color: isSelected ? AppTheme.primaryBlue.withOpacity(0.08) : null,
      child: InkWell(
        onTap: () => _showUnitDetailDrawer(unit),
        child: SizedBox(
          height: rowHeight,
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Checkbox(
                  value: isSelected,
                  onChanged: (_) {
                    setState(() {
                      if (isSelected) _selectedUnitIds.remove(unit.id);
                      else _selectedUnitIds.add(unit.id);
                    });
                  },
                ),
              ),
              Expanded(flex: 1, child: Text(unit.unitNumber, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              Expanded(flex: 2, child: Text(_tenantDisplayName(unit, tenantMap), style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              Expanded(flex: 2, child: Text(tenant != null ? '${tenant.phone} / ${tenant.email}' : '—', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
              Expanded(flex: 1, child: Text(unit.tenantId != null ? '\$${balance.toStringAsFixed(2)}' : '—', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              Expanded(
                flex: 1,
                child: unit.isOverlocked
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppTheme.error.withOpacity(0.15), borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.error)),
                        child: const Text('OVERLOCKED', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600, fontSize: 10)),
                      )
                    : const Text('—', style: TextStyle(fontSize: 12)),
              ),
              Expanded(
                flex: 2,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (unit.isOverlocked)
                      TextButton(
                        onPressed: _loading ? null : () => _singleOverlock(unit, false),
                        child: const Text('Remove'),
                      )
                    else
                      TextButton(
                        onPressed: _loading ? null : () => _singleOverlock(unit, true),
                        child: const Text('Overlock'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Only show units that have a current tenant (or no tenant). Hide "ghost" units where
  /// tenantId points to a deleted/missing tenant.
  List<UnitModel> _filterUnits(List<UnitModel> units, Map<String, TenantModel> tenantMap, Map<String, double> balances) {
    return units.where((u) {
      if (u.tenantId != null && u.tenantId!.isNotEmpty && !tenantMap.containsKey(u.tenantId)) {
        return false;
      }
      if (_statusFilter == 'overlocked' && !u.isOverlocked) return false;
      if (_statusFilter == 'not_overlocked' && u.isOverlocked) return false;
      final balance = u.tenantId != null ? (balances[u.tenantId] ?? 0) : 0.0;
      final isDelinquent = balance > 0;
      if (_delinquencyFilter == 'delinquent' && !isDelinquent) return false;
      if (_delinquencyFilter == 'not_delinquent' && isDelinquent) return false;
      if (_searchQuery.isNotEmpty) {
        final tenant = u.tenantId != null ? tenantMap[u.tenantId] : null;
        final phoneDigits = tenant?.phone.replaceAll(RegExp(r'\D'), '') ?? '';
        final match = u.unitNumber.toLowerCase().contains(_searchQuery) ||
            (u.tenantName?.toLowerCase().contains(_searchQuery) ?? false) ||
            (tenant?.email.toLowerCase().contains(_searchQuery) ?? false) ||
            (tenant?.name.toLowerCase().contains(_searchQuery) ?? false) ||
            phoneDigits.contains(_searchQuery.replaceAll(RegExp(r'\D'), ''));
        if (!match) return false;
      }
      return true;
    }).toList();
  }

  String _tenantDisplayName(UnitModel unit, Map<String, TenantModel> tenantMap) {
    if (unit.tenantId == null || unit.tenantId!.isEmpty) return '—';
    final tenant = tenantMap[unit.tenantId];
    return tenant?.name ?? '—';
  }

  Widget _buildCardList(BuildContext context, double width, List<FacilityModel> facilities) {
    if (_facilityId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final resolved = _resolveData(facilities);
    if (resolved == null) return const Center(child: CircularProgressIndicator());
    final rows = _filterUnits(resolved.units, resolved.tenantMap, resolved.balances);
    if (rows.isEmpty) {
      return const Center(child: Text('No units match filters'));
    }
    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: Breakpoints.isPhone(width) ? 12 : 16, vertical: 8),
      itemCount: rows.length,
      itemBuilder: (context, index) =>
          _buildOverlockCard(context, rows[index], resolved.tenantMap, resolved.balances),
    );
  }

  Widget _buildOverlockCard(
    BuildContext context,
    UnitModel unit,
    Map<String, TenantModel> tenantMap,
    Map<String, double> balances,
  ) {
    final tenant = unit.tenantId != null ? tenantMap[unit.tenantId] : null;
    final balance = unit.tenantId != null ? (balances[unit.tenantId] ?? 0) : 0.0;
    final isSelected = _selectedUnitIds.contains(unit.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _showUnitDetailDrawer(unit),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (_selectModeMobile)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Checkbox(
                        value: isSelected,
                        onChanged: (_) {
                          setState(() {
                            if (isSelected) _selectedUnitIds.remove(unit.id);
                            else _selectedUnitIds.add(unit.id);
                          });
                        },
                      ),
                    ),
                  Text(unit.unitNumber, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  if (unit.isOverlocked) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.error),
                      ),
                      child: const Text('OVERLOCKED', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600, fontSize: 10)),
                    ),
                  ],
                  const Spacer(),
                  if (unit.tenantId != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
                      child: Text('\$${balance.toStringAsFixed(2)}', style: Theme.of(context).textTheme.labelLarge),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(_tenantDisplayName(unit, tenantMap), style: Theme.of(context).textTheme.bodyMedium),
              if (tenant != null)
                Text('${tenant.phone} · ${tenant.email}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (unit.isOverlocked)
                    FilledButton.tonalIcon(
                      onPressed: _loading ? null : () => _singleOverlock(unit, false),
                      icon: const Icon(Icons.lock_open, size: 18),
                      label: const Text('Remove Overlock'),
                    )
                  else
                    FilledButton.tonalIcon(
                      onPressed: _loading ? null : () => _singleOverlock(unit, true),
                      icon: const Icon(Icons.lock, size: 18),
                      label: const Text('Mark Overlocked'),
                    ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (v) {
                      if (v == 'detail') _showUnitDetailDrawer(unit);
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'detail', child: Text('View details')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileBulkBar(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12).copyWith(bottom: 12 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue.withOpacity(0.12),
        border: Border(top: BorderSide(color: AppTheme.borderLight)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Text('${_selectedUnitIds.length} selected', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 12),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: _loading ? null : () => _bulkOverlock(true),
                      child: const Text('Overlock'),
                    ),
                    TextButton(
                      onPressed: _loading ? null : () => _bulkOverlock(false),
                      child: const Text('Remove'),
                    ),
                    TextButton(
                      onPressed: () => _overlockAllDelinquent(),
                      child: const Text('All delinquent'),
                    ),
                    TextButton(
                      onPressed: () => _clearOverlockAll(),
                      child: const Text('Clear all'),
                    ),
                    TextButton(
                      onPressed: () => _printOverlockList(),
                      child: const Text('Print'),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() => _selectedUnitIds.clear()),
              tooltip: 'Clear selection',
            ),
          ],
        ),
      ),
    );
  }

  DataRow _buildRow(UnitModel unit, Map<String, TenantModel> tenantMap, Map<String, double> balances) {
    final tenant = unit.tenantId != null ? tenantMap[unit.tenantId] : null;
    final balance = unit.tenantId != null ? (balances[unit.tenantId] ?? 0) : 0.0;
    final isSelected = _selectedUnitIds.contains(unit.id);

    return DataRow(
      selected: isSelected,
      onSelectChanged: (_) {
        setState(() {
          if (isSelected) {
            _selectedUnitIds.remove(unit.id);
          } else {
            _selectedUnitIds.add(unit.id);
          }
        });
      },
      cells: [
        DataCell(Checkbox(
          value: isSelected,
          onChanged: (_) {
            setState(() {
              if (isSelected) {
                _selectedUnitIds.remove(unit.id);
              } else {
                _selectedUnitIds.add(unit.id);
              }
            });
          },
        )),
        DataCell(
          Text(unit.unitNumber),
          onTap: () => _showUnitDetailDrawer(unit),
        ),
        DataCell(
          Text(_tenantDisplayName(unit, tenantMap)),
          onTap: () => _showUnitDetailDrawer(unit),
        ),
        DataCell(
          Text(tenant != null ? '${tenant.phone} / ${tenant.email}' : '—'),
          onTap: () => _showUnitDetailDrawer(unit),
        ),
        DataCell(
          Text(unit.tenantId != null ? '\$${balance.toStringAsFixed(2)}' : '—'),
          onTap: () => _showUnitDetailDrawer(unit),
        ),
        DataCell(
          unit.isOverlocked
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppTheme.error),
                  ),
                  child: const Text('OVERLOCKED', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600, fontSize: 11)),
                )
              : const Text('—'),
          onTap: () => _showUnitDetailDrawer(unit),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unit.isOverlocked)
                TextButton(
                  onPressed: _loading ? null : () => _singleOverlock(unit, false),
                  child: const Text('Remove Overlock'),
                )
              else
                TextButton(
                  onPressed: _loading ? null : () => _singleOverlock(unit, true),
                  child: const Text('Mark Overlocked'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _singleOverlock(UnitModel unit, bool isOverlocked) async {
    String? note;
    if (isOverlocked) {
      note = await _showNoteDialog(
        title: 'Mark unit overlocked',
        required: true,
        hint: 'Reason (required)',
      );
      if (note == null || note.isEmpty) return;
    } else {
      note = await _showNoteDialog(
        title: 'Remove overlock',
        required: false,
        hint: 'Note (optional)',
      );
    }
    setState(() => _loading = true);
    try {
      final result = await OverlockService.setUnitOverlockStatus(
        facilityId: unit.facilityId,
        unitId: unit.id,
        isOverlocked: isOverlocked,
        note: note?.isEmpty ?? true ? null : note,
      );
      if (!mounted) return;
      if (result.alreadyInState) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isOverlocked ? 'Unit already overlocked' : 'Unit not overlocked'), backgroundColor: AppTheme.info),
        );
      } else if (result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isOverlocked ? 'Unit marked overlocked' : 'Overlock removed'), backgroundColor: AppTheme.success),
        );
        ref.invalidate(facilityUnitsProvider(unit.facilityId));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bulkOverlock(bool isOverlocked) async {
    if (_facilityId == null || _selectedUnitIds.isEmpty) return;
    String? note;
    if (isOverlocked) {
      note = await _showNoteDialog(
        title: 'Overlock ${_selectedUnitIds.length} unit(s)',
        required: true,
        hint: 'Reason (required for all)',
      );
      if (note == null || note.isEmpty) return;
    }
    final count = _selectedUnitIds.length;
    final ok = await _showConfirmBulkDialog(
      count: count,
      action: isOverlocked ? 'Overlock' : 'Remove overlock',
      unitIds: _selectedUnitIds.toList(),
    );
    if (!ok) return;
    setState(() => _loading = true);
    try {
      final result = await OverlockService.setUnitsOverlockStatusBulk(
        facilityId: _facilityId!,
        unitIds: _selectedUnitIds.toList(),
        isOverlocked: isOverlocked,
        note: note?.isEmpty ?? true ? null : note,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Updated ${result.totalUpdated} unit(s). Already in state: ${result.alreadyInStateCount}'),
          backgroundColor: AppTheme.success,
        ),
      );
      setState(() => _selectedUnitIds.clear());
      ref.invalidate(facilityUnitsProvider(_facilityId!));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _overlockAllDelinquent() async {
    if (_facilityId == null) return;
    final note = await _showNoteDialog(
      title: 'Overlock all delinquent units',
      required: true,
      hint: 'Reason (required)',
    );
    if (note == null || note.isEmpty) return;
    setState(() => _loading = true);
    try {
      final result = await OverlockService.overlockAllDelinquent(
        facilityId: _facilityId!,
        note: note,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message ?? 'Overlocked ${result.totalUpdated} unit(s).'),
          backgroundColor: AppTheme.success,
        ),
      );
      ref.invalidate(facilityUnitsProvider(_facilityId!));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clearOverlockAll() async {
    if (_facilityId == null) return;
    final typed = await _showClearConfirmDialog();
    if (typed != true) return;
    setState(() => _loading = true);
    try {
      final result = await OverlockService.clearOverlockByFilter(
        facilityId: _facilityId!,
        confirmToken: 'CLEAR',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message ?? 'Cleared overlock on ${result.totalUpdated} unit(s).'),
          backgroundColor: AppTheme.success,
        ),
      );
      setState(() => _selectedUnitIds.clear());
      ref.invalidate(facilityUnitsProvider(_facilityId!));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _printOverlockList() async {
    if (_facilityId == null) return;
    final authState = ref.read(authStateProvider).value;
    if (authState != null) {
      ref.invalidate(userFacilitiesProvider(authState.uid));
    }
    final facilities = authState != null ? await ref.read(userFacilitiesProvider(authState.uid).future) : <FacilityModel>[];
    String facilityName = _facilityId!;
    for (final f in facilities) {
      if (f.id == _facilityId) {
        facilityName = f.name;
        break;
      }
    }
    final unitsAsync = ref.read(facilityUnitsProvider(_facilityId!));
    final units = unitsAsync.when(
      data: (list) => list.where((u) => u.isOverlocked).toList(),
      loading: () => <UnitModel>[],
      error: (_, __) => <UnitModel>[],
    );
    final tenants = await ref.read(facilityTenantsProvider(_facilityId!).future);
    final tenantMap = {for (final t in tenants) t.id: t};
    final balances = await ref.read(facilityBalancesProvider(_facilityId!).future);

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _OverlockPrintView(
          facilityName: facilityName,
          units: units,
          tenantMap: tenantMap,
          balances: balances,
        ),
      ),
    );
  }

  void _showUnitDetailDrawer(UnitModel unit) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.25,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => _UnitOverlockDetailSheet(
          unit: unit,
          facilityId: _facilityId!,
          onOverlockChanged: () {
            ref.invalidate(facilityUnitsProvider(unit.facilityId));
          },
          onClose: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  Future<String?> _showNoteDialog({required String title, required bool required, required String hint}) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final t = controller.text.trim();
              if (required && t.isEmpty) return;
              Navigator.of(ctx).pop(t.isEmpty ? null : t);
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Future<bool> _showConfirmBulkDialog({required int count, required String action, required List<String> unitIds}) async {
    final preview = unitIds.take(10).toList();
    final more = count > 10 ? count - 10 : 0;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$action $count unit(s)?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Units affected: $count'),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...preview.map((id) => Text('• $id', style: const TextStyle(fontSize: 12))),
              if (more > 0) Text('+ $more more', style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Confirm')),
        ],
      ),
    ).then((v) => v ?? false);
  }

  Future<bool?> _showClearConfirmDialog() async {
    final controller = TextEditingController();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Clear overlock for all (filtered)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('This will remove overlock from all currently overlocked units in this facility. Type CLEAR to confirm.'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: 'Type CLEAR',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            FilledButton(
              onPressed: controller.text.trim() == 'CLEAR' ? () => Navigator.of(ctx).pop(true) : null,
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnitOverlockDetailSheet extends ConsumerWidget {
  final UnitModel unit;
  final String facilityId;
  final VoidCallback onOverlockChanged;
  final VoidCallback onClose;

  const _UnitOverlockDetailSheet({
    required this.unit,
    required this.facilityId,
    required this.onOverlockChanged,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        AppBar(
          title: Text('Unit ${unit.unitNumber}'),
          actions: [IconButton(icon: const Icon(Icons.close), onPressed: onClose)],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (unit.isOverlocked)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.error),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lock, color: AppTheme.error),
                      SizedBox(width: 8),
                      Text('This unit is OVERLOCKED', style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.error)),
                    ],
                  ),
                ),
              const Text('Overlock history', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              StreamBuilder<List<OverlockEventModel>>(
                stream: OverlockService.overlockEventsStream(facilityId, unit.id),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const SizedBox(height: 24, child: Center(child: CircularProgressIndicator()));
                  final events = snapshot.data!;
                  if (events.isEmpty) return const Text('No overlock events');
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: events.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${e.action} by ${e.byName ?? e.byUid} at ${DateFormat.yMd().add_Hm().format(e.at)}${e.note != null && e.note!.isNotEmpty ? "\nNote: ${e.note}" : ""}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    )).toList(),
                  );
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (unit.isOverlocked)
                    FilledButton.icon(
                      onPressed: () async {
                        final result = await OverlockService.setUnitOverlockStatus(
                          facilityId: unit.facilityId,
                          unitId: unit.id,
                          isOverlocked: false,
                          note: 'Removed from detail',
                        );
                        if (result.ok) {
                          onOverlockChanged();
                          if (context.mounted) Navigator.of(context).pop();
                        }
                      },
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Remove Overlock'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: () async {
                        final note = await showDialog<String>(
                          context: context,
                          builder: (ctx) {
                            final c = TextEditingController();
                            return AlertDialog(
                              title: const Text('Mark overlocked'),
                              content: TextField(
                                controller: c,
                                decoration: const InputDecoration(hintText: 'Reason (required)'),
                                maxLines: 2,
                              ),
                              actions: [
                                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                                FilledButton(
                                  onPressed: () {
                                    if (c.text.trim().isNotEmpty) Navigator.of(ctx).pop(c.text.trim());
                                  },
                                  child: const Text('Confirm'),
                                ),
                              ],
                            );
                          },
                        );
                        if (note != null && note.isNotEmpty) {
                          final result = await OverlockService.setUnitOverlockStatus(
                            facilityId: unit.facilityId,
                            unitId: unit.id,
                            isOverlocked: true,
                            note: note,
                          );
                          if (result.ok) {
                            onOverlockChanged();
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        }
                      },
                      icon: const Icon(Icons.lock),
                      label: const Text('Mark Overlocked'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OverlockPrintView extends StatelessWidget {
  final String facilityName;
  final List<UnitModel> units;
  final Map<String, TenantModel> tenantMap;
  final Map<String, double> balances;

  const _OverlockPrintView({
    required this.facilityName,
    required this.units,
    required this.tenantMap,
    required this.balances,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Overlock List'),
        actions: [
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: () => printWindow(),
            tooltip: 'Print overlock list',
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(facilityName, style: Theme.of(context).textTheme.headlineSmall),
              Text('Generated: ${DateFormat.yMd().add_Hm().format(DateTime.now())}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              DataTable(
                columns: const [
                  DataColumn(label: Text('Unit #')),
                  DataColumn(label: Text('Size')),
                  DataColumn(label: Text('Tenant')),
                  DataColumn(label: Text('Phone')),
                  DataColumn(label: Text('Amount Owed')),
                  DataColumn(label: Text('Overlocked Since')),
                  DataColumn(label: Text('Note')),
                ],
                rows: units.map((u) {
                  final tenant = u.tenantId != null ? tenantMap[u.tenantId] : null;
                  final balance = u.tenantId != null ? (balances[u.tenantId] ?? 0) : 0.0;
                  final since = u.overlock?.updatedAt;
                  final note = u.overlock?.reasonNote ?? '—';
                  return DataRow(
                    cells: [
                      DataCell(Text(u.unitNumber)),
                      DataCell(Text(u.dimensions != null ? '${u.dimensions!['width']}x${u.dimensions!['depth']}' : '—')),
                      DataCell(Text(tenant?.name ?? '—')),
                      DataCell(Text(tenant?.phone ?? '—')),
                      DataCell(Text('\$${balance.toStringAsFixed(2)}')),
                      DataCell(Text(since != null ? DateFormat.yMd().add_Hm().format(since) : '—')),
                      DataCell(Text(note)),
                    ],
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
