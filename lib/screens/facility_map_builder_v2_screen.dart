import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
                  _OperationsMapView(key: ValueKey(widget.facilityId), facilityId: widget.facilityId),
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

/// Canvas layout for Operations — same padding/minimum size idea as [FacilityMapEditorScreen].
class _OperationsCanvasLayout {
  const _OperationsCanvasLayout({
    required this.minX,
    required this.minY,
    required this.width,
    required this.height,
  });

  final double minX;
  final double minY;
  final double width;
  final double height;
}

_OperationsCanvasLayout _operationsLayoutForShapes(List<MapShapeModel> shapes) {
  double minX = 0;
  double minY = 0;
  double maxX = 2000.0;
  double maxY = 1500.0;
  if (shapes.isNotEmpty) {
    for (final s in shapes) {
      final right = s.x + s.width;
      final bottom = s.y + s.height;
      if (s.x < minX) minX = s.x;
      if (s.y < minY) minY = s.y;
      if (right > maxX) maxX = right;
      if (bottom > maxY) maxY = bottom;
    }
    minX -= 200;
    minY -= 200;
    maxX += 200;
    maxY += 200;
  }
  if (maxX - minX < 2000) {
    maxX = minX + 2000;
  }
  if (maxY - minY < 1500) {
    maxY = minY + 1500;
  }
  return _OperationsCanvasLayout(
    minX: minX,
    minY: minY,
    width: maxX - minX,
    height: maxY - minY,
  );
}

void _operationsFitTransform(
  TransformationController controller,
  double canvasW,
  double canvasH,
  Size viewport,
) {
  if (viewport.width <= 0 || viewport.height <= 0 || canvasW <= 0 || canvasH <= 0) {
    return;
  }
  final fitScale = (viewport.width / canvasW < viewport.height / canvasH
          ? viewport.width / canvasW
          : viewport.height / canvasH)
      .clamp(0.02, 4.0);
  final translateX = (viewport.width - canvasW * fitScale) / 2;
  final translateY = (viewport.height - canvasH * fitScale) / 2;
  controller.value = Matrix4.identity()
    ..translate(translateX, translateY)
    ..scale(fitScale);
}

int _operationsLayoutSignature(List<MapShapeModel> shapes, _OperationsCanvasLayout layout) {
  var h = Object.hash(shapes.length, layout.minX, layout.minY, layout.width, layout.height);
  for (final s in shapes) {
    h = Object.hash(h, s.id, s.x, s.y, s.width, s.height, s.zIndex);
  }
  return h;
}

class _OperationsMapView extends ConsumerStatefulWidget {
  final String facilityId;

  _OperationsMapView({super.key, required this.facilityId});

  @override
  ConsumerState<_OperationsMapView> createState() => _OperationsMapViewState();
}

class _OperationsMapViewState extends ConsumerState<_OperationsMapView> {
  final TransformationController _transform = TransformationController();
  int? _lastAutoFitSignature;
  _OperationsCanvasLayout? _lastLayout;
  Size _lastViewport = Size.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _zoomBy(double factor) {
    final vs = _lastViewport;
    if (vs.width <= 0 || vs.height <= 0) return;
    final focal = Offset(vs.width / 2, vs.height / 2);
    final currentScale = _transform.value.getMaxScaleOnAxis();
    final targetScale = (currentScale * factor).clamp(0.02, 4.0);
    final scaleChange = targetScale / currentScale;
    _transform.value = _transform.value.clone()
      ..translate(focal.dx, focal.dy)
      ..scale(scaleChange)
      ..translate(-focal.dx, -focal.dy);
    setState(() {});
  }

  void _fitMapToView() {
    final layout = _lastLayout;
    final vs = _lastViewport;
    if (layout == null || vs.width <= 0 || vs.height <= 0) return;
    _operationsFitTransform(_transform, layout.width, layout.height, vs);
    setState(() {});
  }

  void _scheduleAutoFit(List<MapShapeModel> shapes, _OperationsCanvasLayout layout, Size viewport) {
    if (!mounted || viewport.width <= 0 || viewport.height <= 0) return;
    final sig = _operationsLayoutSignature(shapes, layout);
    if (_lastAutoFitSignature == sig) return;
    void run() {
      if (!mounted) return;
      _operationsFitTransform(_transform, layout.width, layout.height, viewport);
      _lastAutoFitSignature = sig;
    }

    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks || phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => run());
    } else {
      run();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shapesAsync = ref.watch(facilityMapShapesProvider(widget.facilityId));
    final unitsAsync = ref.watch(facilityUnitsProvider(widget.facilityId));
    return shapesAsync.when(
      data: (shapes) => unitsAsync.when(
        data: (units) => LayoutBuilder(
          builder: (context, constraints) {
            final layout = _operationsLayoutForShapes(shapes);
            final viewport = Size(constraints.maxWidth, constraints.maxHeight);
            _lastLayout = layout;
            _lastViewport = viewport;
            _scheduleAutoFit(shapes, layout, viewport);
            final cs = Theme.of(context).colorScheme;
            return Stack(
              fit: StackFit.expand,
              children: [
                _buildMap(context, shapes, units, layout),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Material(
                    elevation: 3,
                    borderRadius: BorderRadius.circular(10),
                    color: cs.surfaceContainerHighest,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Zoom in',
                          icon: const Icon(Icons.add),
                          color: cs.onSurface,
                          onPressed: () => _zoomBy(1.15),
                        ),
                        const SizedBox(height: 2),
                        IconButton(
                          tooltip: 'Zoom out',
                          icon: const Icon(Icons.remove),
                          color: cs.onSurface,
                          onPressed: () => _zoomBy(0.85),
                        ),
                        const SizedBox(height: 2),
                        IconButton(
                          tooltip: 'Fit map to view',
                          icon: const Icon(Icons.center_focus_strong),
                          color: cs.primary,
                          onPressed: _fitMapToView,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load units: $e')),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load map: $e')),
    );
  }

  Widget _buildMap(
    BuildContext context,
    List<MapShapeModel> shapes,
    List<UnitModel> units,
    _OperationsCanvasLayout layout,
  ) {
    final byId = {for (final unit in units) unit.id: unit};
    final sorted = [...shapes]..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    return InteractiveViewer(
      transformationController: _transform,
      constrained: false,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      minScale: 0.02,
      maxScale: 4.0,
      child: SizedBox(
        width: layout.width,
        height: layout.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: sorted.map((shape) {
            final unit = shape.unitId == null ? null : byId[shape.unitId];
            final status = unit?.status ?? UnitStatus.available;
            final color = _statusColor(status);
            return Positioned(
              left: shape.x - layout.minX,
              top: shape.y - layout.minY,
              child: InkWell(
                onTap: unit == null
                    ? null
                    : () => context.push(
                          '${AppRoute.unitDetail}?facilityId=${widget.facilityId}&unitId=${unit.id}',
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
