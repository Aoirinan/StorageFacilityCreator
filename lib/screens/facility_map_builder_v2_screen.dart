import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_map_v2_models.dart';
import 'package:sfcapp/models/map_shape_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/facility_map_editor_screen.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class FacilityMapBuilderV2Screen extends ConsumerStatefulWidget {
  final String facilityId;

  const FacilityMapBuilderV2Screen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<FacilityMapBuilderV2Screen> createState() => _FacilityMapBuilderV2ScreenState();
}

class _FacilityMapBuilderV2ScreenState extends ConsumerState<FacilityMapBuilderV2Screen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _publishing = false;
  bool _rollingBack = false;
  bool _copying = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    Future.microtask(() => FacilityMapV2Service.migrateLegacyMapToInitialVersion(widget.facilityId));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    setState(() => _publishing = true);
    try {
      await FacilityMapV2Service.publishCurrentDraft(facilityId: widget.facilityId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Published map snapshot successfully'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Publish failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _copyPublicUrl(String slug) async {
    setState(() => _copying = true);
    try {
      final url = FacilityMapV2Service.buildPublicMapUrl(slug);
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied public URL: $url'),
          backgroundColor: AppTheme.success,
        ),
      );
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FacilityMapMeta>(
      stream: FacilityMapV2Service.metaStream(widget.facilityId),
      builder: (context, metaSnap) {
        final meta = metaSnap.data;
        return Column(
          children: [
            _buildTopBar(meta),
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(icon: Icon(Icons.edit), text: 'Builder'),
                Tab(icon: Icon(Icons.map), text: 'Operations'),
                Tab(icon: Icon(Icons.history), text: 'Versions'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  FacilityMapEditorScreen(facilityId: widget.facilityId),
                  _OperationsMapView(facilityId: widget.facilityId),
                  _VersionHistoryTab(
                    facilityId: widget.facilityId,
                    onRollback: (versionId) async {
                      setState(() => _rollingBack = true);
                      try {
                        await FacilityMapV2Service.rollbackToVersion(
                          facilityId: widget.facilityId,
                          versionId: versionId,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Rollback completed'),
                            backgroundColor: AppTheme.success,
                          ),
                        );
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Rollback failed: $e'),
                            backgroundColor: AppTheme.error,
                          ),
                        );
                      } finally {
                        if (mounted) setState(() => _rollingBack = false);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTopBar(FacilityMapMeta? meta) {
    final slug = meta?.publicSlug ?? widget.facilityId;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Map V2: $slug',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (_rollingBack)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          TextButton.icon(
            onPressed: _copying ? null : () => _copyPublicUrl(slug),
            icon: const Icon(Icons.link),
            label: const Text('Copy Public URL'),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => FacilityMapV2Service.setFacilityV2Enabled(
              facilityId: widget.facilityId,
              enabled: false,
            ),
            child: const Text('Use Legacy'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _publishing ? null : _publish,
            icon: _publishing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.publish),
            label: Text(_publishing ? 'Publishing...' : 'Publish'),
          ),
        ],
      ),
    );
  }
}

class _VersionHistoryTab extends StatelessWidget {
  final String facilityId;
  final Future<void> Function(String versionId) onRollback;

  const _VersionHistoryTab({
    required this.facilityId,
    required this.onRollback,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<FacilityMapVersion>>(
      stream: FacilityMapV2Service.versionsStream(facilityId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final versions = snapshot.data ?? const <FacilityMapVersion>[];
        if (versions.isEmpty) {
          return const Center(child: Text('No versions published yet'));
        }
        return ListView.separated(
          itemCount: versions.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final v = versions[index];
            return ListTile(
              leading: Icon(
                v.status == FacilityMapVersionStatus.published ? Icons.verified : Icons.history,
                color: v.status == FacilityMapVersionStatus.published ? AppTheme.success : null,
              ),
              title: Text('Version ${v.versionNumber} (${v.status.name})'),
              subtitle: Text(
                'Elements: ${v.elements.length} • ${v.publishedAt ?? v.createdAt ?? DateTime.now()}',
              ),
              trailing: TextButton(
                onPressed: () => onRollback(v.id),
                child: const Text('Rollback'),
              ),
            );
          },
        );
      },
    );
  }
}

class _OperationsMapView extends ConsumerWidget {
  final String facilityId;

  const _OperationsMapView({required this.facilityId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shapesAsync = ref.watch(facilityMapShapesProvider(facilityId));
    final unitsAsync = ref.watch(facilityUnitsProvider(facilityId));
    return shapesAsync.when(
      data: (shapes) => unitsAsync.when(
        data: (units) => _buildMap(context, shapes, units),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load units: $e')),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load map: $e')),
    );
  }

  Widget _buildMap(BuildContext context, List<MapShapeModel> shapes, List<UnitModel> units) {
    final byId = {for (final unit in units) unit.id: unit};
    final sorted = [...shapes]..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    return InteractiveViewer(
      minScale: 0.2,
      maxScale: 4,
      child: SizedBox(
        width: 2200,
        height: 1600,
        child: Stack(
          children: sorted.map((shape) {
            final unit = shape.unitId == null ? null : byId[shape.unitId];
            final status = unit?.status ?? UnitStatus.available;
            final color = _statusColor(status);
            return Positioned(
              left: shape.x,
              top: shape.y,
              child: InkWell(
                onTap: unit == null
                    ? null
                    : () => context.push(
                          '${AppRoute.unitDetail}?facilityId=$facilityId&unitId=${unit.id}',
                        ),
                child: Container(
                  width: shape.width,
                  height: shape.height,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.2),
                    border: Border.all(color: color, width: 2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: Text(
                      unit == null ? 'Unassigned' : '${unit.unitNumber}\n${unit.statusDisplayName}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Color _statusColor(UnitStatus status) {
    switch (status) {
      case UnitStatus.available:
        return AppTheme.success;
      case UnitStatus.reserved:
        return AppTheme.warning;
      case UnitStatus.occupied:
        return AppTheme.primaryBlue;
      case UnitStatus.maintenance:
      case UnitStatus.outOfOrder:
      case UnitStatus.overlocked:
      case UnitStatus.lockout:
      case UnitStatus.auction:
        return AppTheme.error;
    }
  }
}
