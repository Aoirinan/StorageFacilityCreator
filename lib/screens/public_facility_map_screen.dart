import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_map_v2_models.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';

class PublicFacilityMapScreen extends StatefulWidget {
  final String facilitySlug;

  const PublicFacilityMapScreen({
    super.key,
    required this.facilitySlug,
  });

  @override
  State<PublicFacilityMapScreen> createState() => _PublicFacilityMapScreenState();
}

class _PublicFacilityMapScreenState extends State<PublicFacilityMapScreen> {
  PublicFacilityMapSnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  bool _listView = false;
  Map<String, dynamic>? _selectedUnit;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await FacilityMapV2Service.getPublicSnapshotBySlug(widget.facilitySlug);
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
        _loading = false;
        _error = snap == null ? 'Map not published' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load map: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _snapshot == null) {
      return Scaffold(body: Center(child: Text(_error ?? 'Unavailable')));
    }
    // publicWebsite.ts gates every SSR entry point on this same flag (404s
    // when off) — without the same check here, turning a facility's public
    // website off in Website Setup would leave this Flutter route still
    // serving a fully working map, disagreeing with the SSR site.
    if (_snapshot!.publicSettings['enabled'] != true) {
      return const Scaffold(body: Center(child: Text('Map not published')));
    }

    final unitsById = {
      for (final u in _snapshot!.units)
        if (u['unitId'] is String) u['unitId'] as String: u,
    };
    // isRentable already folds in status, tenant links, unit-type visibility, and the
    // per-unit publicListingEnabled flag — do not re-derive from raw status here, or
    // staff-only units (manager residence, office, personal-use, etc.) leak into the
    // public map's rentable list even though they're internally `available`.
    final rentableUnits =
        _snapshot!.units.where((u) => u['isRentable'] == true).toList();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        title: Text(
          'Facility Map • ${_snapshot!.facilitySlug}',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
        ),
        actions: [
          IconButton(
            onPressed: () => setState(() => _listView = !_listView),
            icon: Icon(_listView ? Icons.grid_view : Icons.view_list),
            tooltip: _listView ? 'Map view' : 'List view',
          ),
        ],
      ),
      body: KeyboardScrollable(
        child: _listView ? _buildListFallback(rentableUnits) : _buildMap(unitsById),
      ),
    );
  }

  Widget _buildMap(Map<String, Map<String, dynamic>> unitsById) {
    final elements = [..._snapshot!.elements]..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    return Row(
      children: [
        Expanded(
          child: InteractiveViewer(
            minScale: 0.2,
            maxScale: 5,
            child: SizedBox(
              width: 2200,
              height: 1600,
              child: Stack(
                children: elements.map((element) {
                  final unit = element.linkedUnitId == null ? null : unitsById[element.linkedUnitId!];
                  final status = unit?['status']?.toString() ?? 'unavailable';
                  final color = _statusColor(status);
                  final hidden = unit?['status'] == 'hidden';
                  if (hidden) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    left: element.x,
                    top: element.y,
                    child: GestureDetector(
                      onTap: unit == null ? null : () => setState(() => _selectedUnit = unit),
                      child: Container(
                        width: element.width,
                        height: element.height,
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.2),
                          border: Border.all(color: color, width: 2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            unit?['unitNumber']?.toString() ?? '',
                            style: TextStyle(color: color, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        if (_selectedUnit != null)
          SizedBox(
            width: 320,
            child: _buildUnitPanel(_selectedUnit!),
          ),
      ],
    );
  }

  Widget _buildListFallback(List<Map<String, dynamic>> units) {
    if (units.isEmpty) {
      return const Center(child: Text('No units currently available'));
    }
    return ListView.separated(
      itemCount: units.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final unit = units[index];
        return ListTile(
          title: Text('Unit ${unit['unitNumber'] ?? ''}'),
          subtitle: Text(
            'Size: ${unit['size'] ?? 'N/A'} • Status: ${unit['status'] ?? 'unavailable'}',
          ),
          trailing: unit['status'] == 'available' || unit['status'] == 'reserved'
              ? ElevatedButton(
                  onPressed: () => _goToRental(unit),
                  child: const Text('Rent Now'),
                )
              : null,
        );
      },
    );
  }

  Widget _buildUnitPanel(Map<String, dynamic> unit) {
    final status = unit['status']?.toString() ?? 'unavailable';
    final rentable = status == 'available' || status == 'reserved';
    final showPricing = (_snapshot!.publicSettings['showPublicPricing'] == true);
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Unit ${unit['unitNumber'] ?? ''}', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(
                onPressed: () => setState(() => _selectedUnit = null),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Size: ${unit['size'] ?? 'N/A'}'),
          const SizedBox(height: 6),
          Text('Status: ${status.toUpperCase()}'),
          if (showPricing && unit['monthlyRate'] != null) ...[
            const SizedBox(height: 6),
            Text('Price: \$${(unit['monthlyRate'] as num).toStringAsFixed(2)}/month'),
          ],
          if (unit['promotionText'] != null) ...[
            const SizedBox(height: 6),
            Text(unit['promotionText'].toString(), style: const TextStyle(color: AppTheme.warning)),
          ],
          const SizedBox(height: 14),
          if (rentable)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _goToRental(unit),
                child: const Text('Rent Now'),
              ),
            )
          else
            const Text(
              'This unit is unavailable and cannot be rented online.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
        ],
      ),
    );
  }

  void _goToRental(Map<String, dynamic> unit) {
    final facilityId = _snapshot!.facilityId;
    final unitId = unit['unitId'];
    context.go('/rental?facilityId=$facilityId&unitId=$unitId');
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'available':
        return AppTheme.success;
      case 'reserved':
        return AppTheme.warning;
      case 'rented':
        return AppTheme.primaryBlue;
      case 'unavailable':
      default:
        return AppTheme.error;
    }
  }
}
