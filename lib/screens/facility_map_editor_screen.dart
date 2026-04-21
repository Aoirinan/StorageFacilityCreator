import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import '../models/map_shape_model.dart';
import '../models/map_layer_model.dart';
import '../models/unit_model.dart';
import '../services/map_layout_service.dart';
import '../providers/unit_provider.dart';
import '../providers/facility_provider.dart';
import '../services/unit_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import 'unit_detail_screen.dart';
import 'unit_creation_screen.dart';
import 'client_list_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../widgets/map_filter_toolbar.dart';
import '../widgets/map_legend.dart';
import '../widgets/map_unit_tooltip.dart';
import '../widgets/map_search_bar.dart';
import '../widgets/map_bulk_actions_toolbar.dart';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import '../services/facility_service.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import 'dart:typed_data';
import 'package:flutter/rendering.dart';
import '../utils/error_message_helper.dart';
import 'package:sfcapp/utils/map_export_stub.dart' if (dart.library.html) 'package:sfcapp/utils/map_export_web.dart' as map_export;

/// Provider for map shapes stream (scoped by facilityId)
final facilityMapShapesProvider = StreamProvider.family<List<MapShapeModel>, String>((ref, facilityId) {
  return MapLayoutService.getMapShapesStream(facilityId).handleError((error, stackTrace) {
    print('❌ Map shapes stream error: $error');
    print('❌ Stack trace: $stackTrace');
    // Return empty list on error so UI can still render
    return <MapShapeModel>[];
  });
});

/// Provider for selected shape state
final selectedMapShapeProvider = StateProvider<String?>((ref) => null);

/// Auto-seed and default "Starter Row" size — not tied to total facility unit count.
const int kMapStarterRowBlockCount = 20;

List<Object> _alphanumericPartsForSort(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return <Object>[''];
  final out = <Object>[];
  for (final m in RegExp(r'\d+|\D+').allMatches(s)) {
    final g = m.group(0)!;
    final n = int.tryParse(g);
    out.add(n ?? g.toLowerCase());
  }
  return out;
}

/// Puts "2" before "10" for typical storage unit labels.
int compareUnitNumbersNatural(String a, String b) {
  final pa = _alphanumericPartsForSort(a);
  final pb = _alphanumericPartsForSort(b);
  final n = pa.length < pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final va = pa[i];
    final vb = pb[i];
    if (va is int && vb is int) {
      final c = va.compareTo(vb);
      if (c != 0) return c;
    } else {
      final c = va.toString().compareTo(vb.toString());
      if (c != 0) return c;
    }
  }
  return pa.length.compareTo(pb.length);
}

/// Interactive facility map editor
class FacilityMapEditorScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const FacilityMapEditorScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<FacilityMapEditorScreen> createState() => _FacilityMapEditorScreenState();
}

/// World-coordinate rectangle for the grey map workspace (matches _buildCanvas sizing).
class _MapWorkspaceBounds {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const _MapWorkspaceBounds({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });
}

class _FacilityMapEditorScreenState extends ConsumerState<FacilityMapEditorScreen>
    with AutomaticKeepAliveClientMixin {
  final TransformationController _transformationController = TransformationController();
  final GlobalKey _mapCanvasKey = GlobalKey(); // Key for RepaintBoundary to capture map
  /// `toScene` must use coordinates in the InteractiveViewer's viewport, not full-screen MediaQuery.
  final GlobalKey _interactiveViewerKey = GlobalKey();
  bool _isDisposed = false;
  String? _selectedShapeId;
  bool _showGrid = true;
  bool _snapToGrid = true;
  double _gridSize = 20.0;
  bool _isSaving = false;
  Offset? _dragOffset;
  String? _draggingShapeId; // Track which shape is currently being dragged
  bool _isResizing = false; // Track if we're resizing instead of dragging
  MapShapeModel? _activeResizeShape; // Local preview while resizing
  Set<UnitStatus> _statusFilters = UnitStatus.values.toSet(); // Show all by default
  bool _showLegend = false;
  String? _hoveredUnitId;
  UnitModel? _selectedUnitForNavigation;
  Set<String> _selectedUnitIds = {}; // For bulk operations
  Set<MapLayerType> _visibleLayers = {MapLayerType.units}; // Visible layers
  bool _isBulkSelectMode = false; // Toggle for bulk selection mode
  double? _lastCanvasMinX;
  double? _lastCanvasMinY;
  double? _lastCanvasWidth;
  double? _lastCanvasHeight;
  bool _shapePointerActive = false;
  String? _pendingFocusShapeId;
  bool _didAutoSeedBottomRow = false;
  bool _isSeedingBottomRow = false;
  bool _isDeletingAllShapes = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    if (kDebugMode) {
      debugPrint('[MapEditor] dispose for facility ${widget.facilityId}');
    }
    _isDisposed = true;
    _transformationController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      debugPrint('[MapEditor] initState for facility ${widget.facilityId}');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(FocusNode());
    });
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && _selectedShapeId != null) {
      if (event.logicalKey == LogicalKeyboardKey.delete) {
        _deleteSelectedShape();
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _nudgeShape(-_gridSize, 0);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _nudgeShape(_gridSize, 0);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _nudgeShape(0, -_gridSize);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _nudgeShape(0, _gridSize);
      }
    }
  }

  @override
  void deactivate() {
    // Clear transient drag state to avoid stale interaction issues when widget is removed.
    _clearDragState();
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant FacilityMapEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.facilityId != widget.facilityId) {
      if (kDebugMode) {
        debugPrint('[MapEditor] facility changed ${oldWidget.facilityId} -> ${widget.facilityId}; resetting transient state.');
      }
      // Reset view and transient state when switching facilities to avoid stale selections
      _selectedShapeId = null;
      _draggingShapeId = null;
      _dragOffset = null;
      _selectedUnitIds.clear();
      _isResizing = false;
      _transformationController.value = Matrix4.identity();
      _didAutoSeedBottomRow = false;
      _isSeedingBottomRow = false;
    }
  }

  void _clearDragState() {
    if (!mounted) return;
    setState(() {
      _dragOffset = null;
      _draggingShapeId = null;
      _isResizing = false;
      _activeResizeShape = null;
      _shapePointerActive = false;
    });
  }

  void _nudgeShape(double deltaX, double deltaY) {
    if (_selectedShapeId == null) return;

    final shapesAsync = ref.read(facilityMapShapesProvider(widget.facilityId));
    shapesAsync.whenData((shapes) {
      final selectedId = _selectedShapeId;
      if (selectedId == null) return;
      final shape = shapes.firstWhere((s) => s.id == selectedId, orElse: () => throw StateError('Shape not found'));
      // Allow shapes to be positioned anywhere (no clamping to original bounds)
      final newX = (shape.x + deltaX).clamp(0.0, double.infinity);
      final newY = (shape.y + deltaY).clamp(0.0, double.infinity);

      MapLayoutService.updateMapShape(
        facilityId: widget.facilityId,
        shapeId: shape.id,
        x: newX,
        y: newY,
      );
    });
  }

  void _resetView() {
    final vs = _interactiveViewerViewportSize();
    final canvasW = _lastCanvasWidth;
    final canvasH = _lastCanvasHeight;

    if (vs.width <= 0 ||
        vs.height <= 0 ||
        canvasW == null ||
        canvasH == null ||
        canvasW <= 0 ||
        canvasH <= 0) {
      _transformationController.value = Matrix4.identity();
      setState(() {});
      return;
    }

    // Fit the entire canvas into the visible viewport and center it.
    final fitScale = (vs.width / canvasW < vs.height / canvasH
            ? vs.width / canvasW
            : vs.height / canvasH)
        .clamp(0.02, 4.0);
    final translateX = (vs.width - (canvasW * fitScale)) / 2;
    final translateY = (vs.height - (canvasH * fitScale)) / 2;

    _transformationController.value = Matrix4.identity()
      ..translate(translateX, translateY)
      ..scale(fitScale);
    setState(() {});
  }

  void _zoomBy(double factor) {
    final vs = _interactiveViewerViewportSize();
    if (vs.width <= 0 || vs.height <= 0) return;
    final focal = Offset(vs.width / 2, vs.height / 2);
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final targetScale = (currentScale * factor).clamp(0.02, 4.0);
    final scaleChange = targetScale / currentScale;

    final next = _transformationController.value.clone()
      ..translate(focal.dx, focal.dy)
      ..scale(scaleChange)
      ..translate(-focal.dx, -focal.dy);
    _transformationController.value = next;
    setState(() {});
  }

  /// Same bounds logic as [_buildCanvas] (all shapes, unfiltered) for placement and clamping.
  _MapWorkspaceBounds _computeWorkspaceBounds(List<MapShapeModel> shapes) {
    double minX = 0;
    double minY = 0;
    double maxX = 2000.0;
    double maxY = 1500.0;

    if (shapes.isNotEmpty) {
      for (final shape in shapes) {
        final shapeRight = shape.x + shape.width;
        final shapeBottom = shape.y + shape.height;
        if (shape.x < minX) minX = shape.x;
        if (shape.y < minY) minY = shape.y;
        if (shapeRight > maxX) maxX = shapeRight;
        if (shapeBottom > maxY) maxY = shapeBottom;
      }
      minX = minX - 200;
      minY = minY - 200;
      maxX = maxX + 200;
      maxY = maxY + 200;
    }

    if (maxX - minX < 2000) {
      maxX = minX + 2000;
    }
    if (maxY - minY < 1500) {
      maxY = minY + 1500;
    }

    return _MapWorkspaceBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  Size _interactiveViewerViewportSize() {
    final ctx = _interactiveViewerKey.currentContext;
    if (ctx == null) return Size.zero;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Size.zero;
    return box.size;
  }

  void _focusShapeOnCanvas(MapShapeModel shape, {int attempt = 0}) {
    final vs = _interactiveViewerViewportSize();
    if (vs.width <= 0 || vs.height <= 0) {
      if (attempt < 12) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isDisposed && mounted) {
            _focusShapeOnCanvas(shape, attempt: attempt + 1);
          }
        });
        return;
      }
      if (kDebugMode) {
        debugPrint(
          '[MapEditor] focus: viewport still 0×0 after retries; identity transform',
        );
      }
      _transformationController.value = Matrix4.identity();
      setState(() {
        _selectedShapeId = shape.id;
        _pendingFocusShapeId = null;
      });
      return;
    }

    final centerX = shape.x + shape.width / 2;
    final centerY = shape.y + shape.height / 2;
    const scale = 1.4;
    final vw = vs.width;
    final vh = vs.height;
    _transformationController.value = Matrix4.identity()
      ..translate(-(centerX * scale) + (vw / 2), -(centerY * scale) + (vh / 2))
      ..scale(scale);
    setState(() {
      _selectedShapeId = shape.id;
      _pendingFocusShapeId = null;
    });
  }

  void _selectShape(String? shapeId) {
    setState(() {
      _selectedShapeId = shapeId;
      _dragOffset = null;
    });
    ref.read(selectedMapShapeProvider.notifier).state = shapeId;
  }

  double _snapToGridValue(double value) {
    return (value / _gridSize).round() * _gridSize;
  }

  Future<void> _addRectangle() async {
    try {
      final shapes = ref.read(facilityMapShapesProvider(widget.facilityId)).asData?.value ??
          const <MapShapeModel>[];
      final bounds = _computeWorkspaceBounds(shapes);

      final vs = _interactiveViewerViewportSize();
      final w = _snapToGridValue(100.0).clamp(_gridSize, 2000.0);
      final h = _snapToGridValue(80.0).clamp(_gridSize, 1500.0);

      final Offset scenePoint;
      if (vs.width > 0 && vs.height > 0) {
        scenePoint = _transformationController.toScene(Offset(vs.width / 2, vs.height / 2));
      } else {
        // Viewer not laid out yet; do not use full-screen coords with [toScene].
        scenePoint = Offset(
          bounds.minX + (bounds.maxX - bounds.minX) / 2,
          bounds.minY + (bounds.maxY - bounds.minY) / 2,
        );
      }
      double defaultX = scenePoint.dx - w / 2;
      double defaultY = scenePoint.dy - h / 2;
      defaultX = _snapToGridValue(defaultX);
      defaultY = _snapToGridValue(defaultY);

      final maxPlaceX = (bounds.maxX - w).clamp(bounds.minX, bounds.maxX);
      final maxPlaceY = (bounds.maxY - h).clamp(bounds.minY, bounds.maxY);
      defaultX = defaultX.clamp(bounds.minX, maxPlaceX);
      defaultY = defaultY.clamp(bounds.minY, maxPlaceY);

      final createdId = await MapLayoutService.createMapShape(
        facilityId: widget.facilityId,
        type: 'rect',
        x: defaultX,
        y: defaultY,
        width: w,
        height: h,
      );

      if (mounted) {
        setState(() {
          _pendingFocusShapeId = createdId;
          _selectedShapeId = createdId;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Shape added'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding shape: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _createBottomStarterBlocks({int? count}) async {
    if (_isSeedingBottomRow) return;
    _isSeedingBottomRow = true;
    try {
      final units = ref.read(facilityUnitsProvider(widget.facilityId)).asData?.value ?? const <UnitModel>[];
      final shapes = ref.read(facilityMapShapesProvider(widget.facilityId)).asData?.value ?? const <MapShapeModel>[];
      final assignedUnitIds = shapes.where((s) => s.unitId != null).map((s) => s.unitId!).toSet();
      final availableUnassignedUnits = units.where((u) => !assignedUnitIds.contains(u.id)).toList()
        ..sort((a, b) => compareUnitNumbersNatural(a.unitNumber, b.unitNumber));

      final requested = count ?? kMapStarterRowBlockCount;
      if (requested <= 0) return;
      final targetCount = requested.clamp(1, 100);

      const maxBlockWidth = 100.0;
      const minBlockWidth = 48.0;
      const blockHeight = 80.0;
      const margin = 30.0;
      final bounds = _computeWorkspaceBounds(shapes);
      final workspaceInnerW = bounds.maxX - bounds.minX - 2 * margin;
      if (workspaceInnerW <= 0) return;

      double gap = 12.0;
      double blockWidth = maxBlockWidth;
      double rowWidth(int n, double w, double g) => n * w + (n > 1 ? (n - 1) * g : 0);
      while (targetCount > 1 && rowWidth(targetCount, blockWidth, gap) > workspaceInnerW && gap > 4) {
        gap -= 2;
      }
      while (targetCount > 1 && rowWidth(targetCount, blockWidth, gap) > workspaceInnerW && blockWidth > minBlockWidth) {
        blockWidth -= 4;
      }
      if (rowWidth(targetCount, blockWidth, gap) > workspaceInnerW && targetCount > 1) {
        gap = 4;
        blockWidth = ((workspaceInnerW - (targetCount - 1) * gap) / targetCount).clamp(minBlockWidth, maxBlockWidth);
      }

      final startX = bounds.minX + margin;
      final y = (bounds.maxY - blockHeight - margin).clamp(bounds.minY, bounds.maxY - blockHeight);

      String? firstCreatedId;
      var assignedCount = 0;
      for (int i = 0; i < targetCount; i++) {
        final unitId =
            i < availableUnassignedUnits.length ? availableUnassignedUnits[i].id : null;
        if (unitId != null) assignedCount++;
        final createdId = await MapLayoutService.createMapShape(
          facilityId: widget.facilityId,
          unitId: unitId,
          type: 'rect',
          x: startX + (i * (blockWidth + gap)),
          y: y,
          width: blockWidth,
          height: blockHeight,
          zIndex: 1,
        );
        firstCreatedId ??= createdId;
      }

      if (mounted && firstCreatedId != null) {
        setState(() {
          _pendingFocusShapeId = firstCreatedId;
          _selectedShapeId = firstCreatedId;
        });
        final unassignedLeft = targetCount - assignedCount;
        final msg = unassignedLeft > 0
            ? 'Created $targetCount blocks ($assignedCount linked to units; $unassignedLeft unassigned)'
            : 'Created $targetCount blocks linked to units along the bottom';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating starter row: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      _isSeedingBottomRow = false;
    }
  }

  Future<void> _deleteAllShapes() async {
    final shapesAsync = ref.read(facilityMapShapesProvider(widget.facilityId));
    final shapes = shapesAsync.asData?.value ?? const <MapShapeModel>[];
    if (shapes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No shapes to delete')),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all map shapes?'),
        content: Text(
          'This removes all ${shapes.length} shapes from the map for this facility. '
          'Your units and tenants are not deleted. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isDeletingAllShapes = true);
    try {
      final removed = await MapLayoutService.deleteAllMapShapes(facilityId: widget.facilityId);
      _selectShape(null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(removed == 0 ? 'No shapes were removed' : 'Removed $removed shapes from the map'),
            backgroundColor: removed == 0 ? null : AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not delete all shapes: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDeletingAllShapes = false);
      }
    }
  }

  Future<void> _deleteSelectedShape() async {
    if (_selectedShapeId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Shape'),
        content: const Text('Are you sure you want to delete this shape?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && _selectedShapeId != null) {
      try {
        await MapLayoutService.deleteMapShape(
          facilityId: widget.facilityId,
          shapeId: _selectedShapeId!,
        );
        _selectShape(null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Shape deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting shape: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _duplicateSelectedShape() async {
    if (_selectedShapeId == null) return;
    final shapesAsync = ref.read(facilityMapShapesProvider(widget.facilityId));
    final shapes = shapesAsync.asData?.value ?? const <MapShapeModel>[];
    final shape = shapes.where((s) => s.id == _selectedShapeId).firstOrNull;
    if (shape == null) return;

    try {
      final createdId = await MapLayoutService.createMapShape(
        facilityId: widget.facilityId,
        type: shape.type,
        x: shape.x + _gridSize,
        y: shape.y + _gridSize,
        width: shape.width,
        height: shape.height,
        rotation: shape.rotation,
        zIndex: shape.zIndex + 1,
        metadata: shape.metadata,
      );
      if (mounted) {
        setState(() {
          _pendingFocusShapeId = createdId;
          _selectedShapeId = createdId;
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Shape duplicated'),
          duration: Duration(seconds: 1),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error duplicating shape: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<void> _saveMap() async {
    setState(() => _isSaving = true);
    try {
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Map saved'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (kDebugMode) {
      debugPrint('[MapEditor] build for facility ${widget.facilityId}');
    }
    final shapesAsync = ref.watch(facilityMapShapesProvider(widget.facilityId));
    final unitsAsync = ref.watch(facilityUnitsProvider(widget.facilityId));

    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: _handleKeyEvent,
      child: Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1),
          MapFilterToolbar(
            selectedStatuses: _statusFilters,
            onStatusFilterChanged: (statuses) {
              setState(() {
                // Empty set would hide every unit-linked shape (starter row, etc.).
                _statusFilters =
                    statuses.isEmpty ? UnitStatus.values.toSet() : statuses;
              });
            },
            showLegend: _showLegend,
            onToggleLegend: () {
              setState(() {
                _showLegend = !_showLegend;
              });
            },
          ),
          if (_selectedUnitIds.isNotEmpty)
            MapBulkActionsToolbar(
              selectedUnitIds: _selectedUnitIds.toList(),
              onClearSelection: () {
                setState(() {
                  _selectedUnitIds.clear();
                });
              },
              onBulkStatusChange: _handleBulkStatusChange,
              onBulkDelete: _handleBulkDelete,
            ),
          Expanded(
            child: RepaintBoundary(
              key: _mapCanvasKey,
              child: Stack(
                children: [
                  shapesAsync.when(
                    data: (shapes) {
                      print('[MapEditor] Shapes loaded: ${shapes.length}');
                      return unitsAsync.when(
                        data: (units) {
                          print('[MapEditor] Units loaded: ${units.length}');
                          return _buildCanvas(shapes, units);
                        },
                        loading: () => const Center(child: CircularProgressIndicator()),
                        error: (e, stack) {
                          print('[MapEditor] ERROR loading units: $e');
                          print('[MapEditor] Stack: $stack');
                          return _buildError('Error loading units: $e');
                        },
                      );
                    },
                    loading: () {
                      print('[MapEditor] Loading shapes...');
                      return const Center(child: CircularProgressIndicator());
                    },
                    error: (e, stack) {
                      print('[MapEditor] ERROR loading shapes: $e');
                      print('[MapEditor] Stack: $stack');
                      return _buildError('Error loading map: $e');
                    },
                  ),
                  if (_showLegend)
                    Positioned(
                      top: 16,
                      right: 16,
                      child: const MapLegend(),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => setState(() {}),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final cs = Theme.of(context).colorScheme;
    final shapesAsync = ref.watch(facilityMapShapesProvider(widget.facilityId));
    final shapeCount = shapesAsync.asData?.value.length ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: cs.surface,
      child: Row(
        children: [
          ElevatedButton.icon(
            onPressed: _addRectangle,
            icon: const Icon(Icons.add_box, size: 20),
            label: const Text('Add Unit'),
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _isSeedingBottomRow ? null : () => _createBottomStarterBlocks(),
            icon: _isSeedingBottomRow
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.view_week, size: 18),
            label: Text(_isSeedingBottomRow ? 'Building...' : 'Starter row ($kMapStarterRowBlockCount)'),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: () => setState(() => _showGrid = !_showGrid),
            icon: Icon(_showGrid ? Icons.grid_on : Icons.grid_off),
            tooltip: 'Toggle Grid',
            color: _showGrid ? cs.primary : cs.onSurfaceVariant,
          ),
          IconButton(
            onPressed: () => setState(() => _snapToGrid = !_snapToGrid),
            icon: Icon(_snapToGrid ? Icons.grid_3x3 : Icons.grid_off),
            tooltip: 'Snap to Grid',
            color: _snapToGrid ? cs.primary : cs.onSurfaceVariant,
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _isBulkSelectMode = !_isBulkSelectMode;
                if (!_isBulkSelectMode) {
                  _selectedUnitIds.clear();
                }
              });
            },
            icon: Icon(_isBulkSelectMode ? Icons.check_box : Icons.check_box_outline_blank),
            tooltip: 'Bulk Select Mode',
            color: _isBulkSelectMode ? cs.primary : cs.onSurfaceVariant,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.layers),
            tooltip: 'Map Layers',
            itemBuilder: (context) => MapLayerType.values.map((layerType) {
              final isVisible = _visibleLayers.contains(layerType);
              return PopupMenuItem(
                value: layerType.name,
                child: Row(
                  children: [
                    Icon(
                      isVisible ? Icons.visibility : Icons.visibility_off,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(_getLayerName(layerType)),
                  ],
                ),
              );
            }).toList(),
            onSelected: (layerName) {
              setState(() {
                final layerType = MapLayerType.values.firstWhere((t) => t.name == layerName);
                if (_visibleLayers.contains(layerType)) {
                  _visibleLayers.remove(layerType);
                } else {
                  _visibleLayers.add(layerType);
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Print Map',
            onPressed: _printMap,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export Map',
            onPressed: _exportMap,
          ),
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            tooltip: 'Reset View',
            onPressed: _resetView,
          ),
          IconButton(
            // zoom_out / zoom_in can be stripped from tree-shaken MaterialIcons on web
            icon: const Icon(Icons.remove),
            tooltip: 'Zoom Out',
            color: cs.onSurface,
            onPressed: () => _zoomBy(0.85),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Zoom In',
            color: cs.onSurface,
            onPressed: () => _zoomBy(1.15),
          ),
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'Shape Manager',
            onPressed: _openShapeManager,
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _isDeletingAllShapes || shapeCount == 0 || shapesAsync.isLoading
                ? null
                : _deleteAllShapes,
            icon: _isDeletingAllShapes
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_sweep, size: 20),
            label: Text(_isDeletingAllShapes ? 'Deleting…' : 'Delete all'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
          ),
          const SizedBox(width: 4),
          if (_selectedShapeId != null)
            IconButton(
              onPressed: _deleteSelectedShape,
              icon: const Icon(Icons.delete),
              tooltip: 'Delete Selected Shape',
              color: AppTheme.error,
            ),
          ElevatedButton.icon(
            onPressed: _isSaving ? null : _saveMap,
            icon: _isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save, size: 20),
            label: Text(_isSaving ? 'Saving...' : 'Save'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.success,
              foregroundColor: cs.onPrimary,
            ),
          ),
        ],
      ),
    );
  }

  void _zoomToShape(MapShapeModel shape) {
    _focusShapeOnCanvas(shape);
  }

  Widget _buildCanvas(List<MapShapeModel> shapes, List<UnitModel> units) {
    try {
      print('[MapEditor] _buildCanvas called with ${shapes.length} shapes, ${units.length} units');
      final unitsMap = {for (var unit in units) unit.id: unit};

      if (!_didAutoSeedBottomRow && shapes.isEmpty && !_isSeedingBottomRow) {
        _didAutoSeedBottomRow = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _createBottomStarterBlocks(count: kMapStarterRowBlockCount);
          }
        });
      }

      if (_pendingFocusShapeId != null) {
        final pending = shapes.where((s) => s.id == _pendingFocusShapeId).firstOrNull;
        if (pending != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _focusShapeOnCanvas(pending);
            }
          });
        }
      }
      
      // Filter shapes based on status filters
      final filteredShapes = shapes.where((shape) {
        if (shape.unitId == null) return true; // Show unassigned shapes
        final unit = unitsMap[shape.unitId];
        if (unit == null) return true;
        return _statusFilters.contains(unit.status);
      }).toList();
      
      print('[MapEditor] Filtered shapes: ${filteredShapes.length}');

      // Calculate dynamic canvas size based on all shapes (including off-map ones)
      // Minimum size is 2000x1500, but expand to accommodate all shapes
      double minX = 0;
      double minY = 0;
      double maxX = 2000.0;
      double maxY = 1500.0;
      
      if (filteredShapes.isNotEmpty) {
        for (final shape in filteredShapes) {
          final shapeRight = shape.x + shape.width;
          final shapeBottom = shape.y + shape.height;
          if (shape.x < minX) minX = shape.x;
          if (shape.y < minY) minY = shape.y;
          if (shapeRight > maxX) maxX = shapeRight;
          if (shapeBottom > maxY) maxY = shapeBottom;
        }
        // Add padding around all shapes (allow negative coordinates)
        minX = minX - 200;
        minY = minY - 200;
        maxX = maxX + 200;
        maxY = maxY + 200;
      }
      
      // Ensure minimum canvas size
      if (maxX - minX < 2000) {
        maxX = minX + 2000;
      }
      if (maxY - minY < 1500) {
        maxY = minY + 1500;
      }
      
      final canvasWidth = maxX - minX;
      final canvasHeight = maxY - minY;

      _lastCanvasMinX = minX;
      _lastCanvasMinY = minY;
      _lastCanvasWidth = canvasWidth;
      _lastCanvasHeight = canvasHeight;
      
      print('[MapEditor] Canvas size: ${canvasWidth}x${canvasHeight}, offset: ($minX, $minY)');

      return InteractiveViewer(
        key: _interactiveViewerKey,
        transformationController: _transformationController,
        // Map canvas is often larger than the viewport; default constrained:true
        // prevents correct layout (see InteractiveViewer.constrained docs).
        constrained: false,
        minScale: 0.02,
        maxScale: 4.0,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        // While dragging/resizing a shape, disable viewport pan to avoid the
        // canvas moving opposite the shape drag.
        panEnabled: !_isResizing && _draggingShapeId == null,
        scaleEnabled: true,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent, // Allow clicks to pass through to shapes
          // Handle clicks on empty canvas to deselect
          onTapDown: (details) {
            if (_isDisposed || !mounted) return;
            if (_selectedShapeId != null && !_shapePointerActive) {
              setState(() {
                _selectedShapeId = null;
              });
            }
          },
          child: Builder(
            builder: (context) {
              final cs = Theme.of(context).colorScheme;
              return Container(
                width: canvasWidth,
                height: canvasHeight,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  border: Border.all(color: cs.outline),
                ),
            child: Stack(
              clipBehavior: Clip.none, // Allow shapes outside bounds to be visible and clickable
              children: [
                // Always show grid if enabled, even with no shapes
                if (_showGrid) _buildGrid(canvasWidth, canvasHeight, minX, minY),
                // Show shapes
                ...filteredShapes.map((shape) => _buildShape(
                      shape,
                      unitsMap[shape.unitId],
                      shape.id == _selectedShapeId,
                      minX,
                      minY,
                    )),
              ],
            ),
              );
            },
          ),
        ),
      );
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[MapEditor] Map render error: $e\n$stack');
      }
      // Log error to console even in production for debugging
      print('[MapEditor] ERROR: Map render failed: $e');
      print('[MapEditor] Stack trace: $stack');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                'Map is temporarily unavailable.',
                style: const TextStyle(color: Colors.redAccent, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Error: $e',
                style: const TextStyle(color: Colors.red, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => setState(() {}),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildGrid(double width, double height, double offsetX, double offsetY) {
    return CustomPaint(
      painter: _GridPainter(
        gridSize: _gridSize,
        color: AppTheme.borderLight.withOpacity(0.3),
        offsetX: offsetX,
        offsetY: offsetY,
      ),
      size: Size(width, height),
    );
  }

  Widget _buildShape(MapShapeModel shape, UnitModel? unit, bool isSelected, double canvasOffsetX, double canvasOffsetY) {
    final renderShape =
        (_activeResizeShape != null && _activeResizeShape!.id == shape.id)
            ? _activeResizeShape!
            : shape;
    final statusColor = unit != null
        ? (unit.isOverlocked ? AppTheme.error : _getUnitStatusColor(unit.status))
        : AppTheme.textTertiary;
    final borderColor = isSelected ? AppTheme.primaryBlue : statusColor;
    final borderWidth = isSelected ? 3.0 : 2.0;

    // Apply drag offset ONLY if this is the shape being dragged
    final isDragging = shape.id == _draggingShapeId && _dragOffset != null;
    final dragOffset = _dragOffset ?? Offset.zero;
    final displayX = (renderShape.x - canvasOffsetX) + (isDragging ? dragOffset.dx : 0);
    final displayY = (renderShape.y - canvasOffsetY) + (isDragging ? dragOffset.dy : 0);

    return Positioned(
      left: displayX,
      top: displayY,
      child: Stack(
        clipBehavior: Clip.none, // Allow resize handles outside bounds
        children: [
          // Listener only on the unit body — not handles. Wrapping handles caused
          // onPointerDown to set _draggingShapeId and remove handles from the tree
          // before the handle's pan gesture could start (resize appeared broken).
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (_isDisposed || !mounted) return;
              if (_isResizing) return;
              _shapePointerActive = true;
              if (kDebugMode) {
                debugPrint('[MapEditor] pointer down (shape) shape=${shape.id}');
              }
              _selectShape(shape.id);
              setState(() {
                _draggingShapeId = shape.id;
                _dragOffset = Offset.zero;
                _isResizing = false;
              });
            },
            onPointerMove: (event) {
              if (_isDisposed || !mounted) return;
              if (_draggingShapeId != shape.id || _isResizing) return;
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              setState(() {
                _dragOffset = Offset(
                  (_dragOffset?.dx ?? 0) + event.delta.dx / scale,
                  (_dragOffset?.dy ?? 0) + event.delta.dy / scale,
                );
              });
            },
            onPointerUp: (event) {
              if (_isDisposed || !mounted) return;
              _shapePointerActive = false;
              if (_draggingShapeId != shape.id || _dragOffset == null || _isResizing) {
                _clearDragState();
                return;
              }
              final dx = _dragOffset!.dx;
              final dy = _dragOffset!.dy;
              if (dx.abs() < 0.5 && dy.abs() < 0.5) {
                _clearDragState();
                return;
              }
              final newX = (shape.x + dx).clamp(0.0, double.infinity);
              final newY = (shape.y + dy).clamp(0.0, double.infinity);
              final snappedX = _snapToGrid
                  ? _snapToGridValue(newX)
                  : newX;
              final snappedY = _snapToGrid
                  ? _snapToGridValue(newY)
                  : newY;
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                x: snappedX.clamp(0.0, double.infinity),
                y: snappedY.clamp(0.0, double.infinity),
              );
              _clearDragState();
            },
            onPointerCancel: (_) {
              _shapePointerActive = false;
              _clearDragState();
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_isDisposed || !mounted) return;
                if (_isBulkSelectMode && unit != null) {
                  // Toggle unit selection in bulk mode
                  setState(() {
                    if (_selectedUnitIds.contains(unit.id)) {
                      _selectedUnitIds.remove(unit.id);
                    } else {
                      _selectedUnitIds.add(unit.id);
                    }
                  });
                } else {
                  // Normal mode: select shape only (avoid disruptive navigation on single click)
                  _selectShape(shape.id);
                }
              },
              onDoubleTap: () {
                if (_isDisposed || !mounted) return;
                _selectShape(shape.id);
                if (unit != null) {
                  _showUnitDetails(unit);
                } else {
                  _showUnitAssignmentDialog(shape);
                }
              },
              onLongPress: () {
                if (_isDisposed || !mounted) return;
                _selectShape(shape.id);
                _showShapeActions(shape, unit);
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                onEnter: (_) {
                  if (unit != null) {
                    setState(() {
                      _hoveredUnitId = unit.id;
                    });
                  }
                },
                onExit: (_) {
                  setState(() {
                    _hoveredUnitId = null;
                  });
                },
                child: SizedBox(
                  width: renderShape.width,
                  height: renderShape.height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.bottomCenter,
                    children: [
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                      width: renderShape.width,
                      height: renderShape.height,
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.2),
                        border: Border.all(
                          color: _selectedUnitIds.contains(unit?.id)
                              ? AppTheme.warning
                              : borderColor,
                          width: _selectedUnitIds.contains(unit?.id) ? 3.0 : borderWidth,
                        ),
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: isSelected || _selectedUnitIds.contains(unit?.id)
                            ? [
                                BoxShadow(
                                  color: (_selectedUnitIds.contains(unit?.id)
                                          ? AppTheme.warning
                                          : AppTheme.primaryBlue)
                                      .withOpacity(0.3),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: 40, // Ensure minimum width for text
                            maxWidth: renderShape.width - 8, // Padding on sides
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (unit != null) ...[
                                // Display unit number and size (e.g., "301 / 10x10")
                                Text(
                                  _formatUnitDisplay(unit),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    color: statusColor,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false, // Prevent wrapping
                                ),
                                Text(
                                  unit.statusDisplayName,
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: statusColor,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false, // Prevent wrapping
                                ),
                                if (unit.isOverlocked)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      'OVERLOCKED',
                                      style: TextStyle(
                                        fontSize: 8,
                                        color: AppTheme.error,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      softWrap: false, // Prevent wrapping
                                    ),
                                  ),
                              ] else
                                Icon(
                                  Icons.crop_free,
                                  size: 24,
                                  color: AppTheme.textTertiary,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ),
                    if (_hoveredUnitId == unit?.id && unit != null)
                      Positioned(
                        top: -148,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minWidth: 220,
                            maxWidth: 320,
                            child: MapUnitTooltip(
                              unit: unit,
                              onViewDetails: () {
                                _showUnitDetails(unit);
                              },
                              onEdit: () {
                                _showUnitAssignmentDialog(shape);
                              },
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                ),
              ),
            ),
          ),
          // Keep handles mounted while resizing so the pan gesture is not torn down.
          if (isSelected &&
              (_draggingShapeId == null ||
                  (_isResizing && _draggingShapeId == shape.id)))
            ..._buildResizeHandles(renderShape),
        ],
      ),
    );
  }

  List<Widget> _buildResizeHandles(MapShapeModel shape) {
    const handleSize = 16.0; // Increased size for better visibility
    const handleColor = AppTheme.primaryBlue;
    
    return [
      // Top-left
      Positioned(
        left: -handleSize / 2,
        bottom: shape.height - handleSize / 2,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            if (kDebugMode) {
              debugPrint('[MapEditor] resize start (top-left) shape=${shape.id}');
            }
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
              _dragOffset = null;
              _activeResizeShape = shape;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final current = _activeResizeShape ?? shape;
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (current.width - deltaX).clamp(20.0, 2000.0);
              final newHeight = (current.height - deltaY).clamp(20.0, 1500.0);
              final newX = (current.x + deltaX).clamp(0.0, 2000.0 - newWidth);
              final newY = (current.y + deltaY).clamp(0.0, 1500.0 - newHeight);

              setState(() {
                _activeResizeShape = current.copyWith(
                  x: newX,
                  y: newY,
                  width: newWidth,
                  height: newHeight,
                );
              });
            }
          },
          onPanEnd: (details) {
            final finalShape = _activeResizeShape;
            if (finalShape != null) {
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                x: finalShape.x,
                y: finalShape.y,
                width: finalShape.width,
                height: finalShape.height,
              );
            }
            _clearDragState();
          },
          onPanCancel: _clearDragState,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            child: Container(
              width: handleSize,
              height: handleSize,
              decoration: BoxDecoration(
                color: handleColor,
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(handleSize / 2),
              ),
            ),
          ),
        ),
      ),
      // Top-right
      Positioned(
        right: -handleSize / 2,
        bottom: shape.height - handleSize / 2,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            if (kDebugMode) {
              debugPrint('[MapEditor] resize start (top-right) shape=${shape.id}');
            }
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
              _dragOffset = null;
              _activeResizeShape = shape;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final current = _activeResizeShape ?? shape;
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (current.width + deltaX).clamp(20.0, 2000.0 - current.x);
              final newHeight = (current.height - deltaY).clamp(20.0, 1500.0);
              final newY = (current.y + deltaY).clamp(0.0, 1500.0 - newHeight);

              setState(() {
                _activeResizeShape = current.copyWith(
                  y: newY,
                  width: newWidth,
                  height: newHeight,
                );
              });
            }
          },
          onPanEnd: (details) {
            final finalShape = _activeResizeShape;
            if (finalShape != null) {
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                y: finalShape.y,
                width: finalShape.width,
                height: finalShape.height,
              );
            }
            _clearDragState();
          },
          onPanCancel: _clearDragState,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
            child: Container(
              width: handleSize,
              height: handleSize,
              decoration: BoxDecoration(
                color: handleColor,
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(handleSize / 2),
              ),
            ),
          ),
        ),
      ),
      // Bottom-left
      Positioned(
        left: -handleSize / 2,
        bottom: -handleSize / 2,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            if (kDebugMode) {
              debugPrint('[MapEditor] resize start (bottom-left) shape=${shape.id}');
            }
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
              _dragOffset = null;
              _activeResizeShape = shape;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final current = _activeResizeShape ?? shape;
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (current.width - deltaX).clamp(20.0, 2000.0);
              final newHeight = (current.height + deltaY).clamp(20.0, 1500.0 - current.y);
              final newX = (current.x + deltaX).clamp(0.0, 2000.0 - newWidth);

              setState(() {
                _activeResizeShape = current.copyWith(
                  x: newX,
                  width: newWidth,
                  height: newHeight,
                );
              });
            }
          },
          onPanEnd: (details) {
            final finalShape = _activeResizeShape;
            if (finalShape != null) {
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                x: finalShape.x,
                width: finalShape.width,
                height: finalShape.height,
              );
            }
            _clearDragState();
          },
          onPanCancel: _clearDragState,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
            child: Container(
              width: handleSize,
              height: handleSize,
              decoration: BoxDecoration(
                color: handleColor,
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(handleSize / 2),
              ),
            ),
          ),
        ),
      ),
      // Bottom-right
      Positioned(
        right: -handleSize / 2,
        bottom: -handleSize / 2,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            if (kDebugMode) {
              debugPrint('[MapEditor] resize start (bottom-right) shape=${shape.id}');
            }
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
              _dragOffset = null;
              _activeResizeShape = shape;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final current = _activeResizeShape ?? shape;
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (current.width + deltaX).clamp(20.0, 2000.0 - current.x);
              final newHeight = (current.height + deltaY).clamp(20.0, 1500.0 - current.y);

              setState(() {
                _activeResizeShape = current.copyWith(
                  width: newWidth,
                  height: newHeight,
                );
              });
            }
          },
          onPanEnd: (details) {
            final finalShape = _activeResizeShape;
            if (finalShape != null) {
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                width: finalShape.width,
                height: finalShape.height,
              );
            }
            _clearDragState();
          },
          onPanCancel: _clearDragState,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            child: Container(
              width: handleSize,
              height: handleSize,
              decoration: BoxDecoration(
                color: handleColor,
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(handleSize / 2),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  String _getLayerName(MapLayerType layerType) {
    switch (layerType) {
      case MapLayerType.units:
        return 'Units';
      case MapLayerType.buildings:
        return 'Buildings';
      case MapLayerType.aisles:
        return 'Aisles';
      case MapLayerType.parking:
        return 'Parking';
      case MapLayerType.labels:
        return 'Labels';
      case MapLayerType.custom:
        return 'Custom';
    }
  }

  void _showUnitDetails(UnitModel unit) {
    context.push(AppRoute.unitDetail, extra: unit);
  }

  void _showUnitAssignmentDialog(MapShapeModel shape) {
    showDialog(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final unitsAsync = ref.watch(facilityUnitsProvider(widget.facilityId));
          final shapesAsync = ref.watch(facilityMapShapesProvider(widget.facilityId));

          return AlertDialog(
            title: const Text('Assign Unit to Shape'),
            content: SizedBox(
              width: 300,
              child: unitsAsync.when(
                data: (units) {
                  return shapesAsync.when(
                    data: (shapes) {
                      final assignedUnitIds = shapes
                          .where((s) => s.unitId != null && s.id != shape.id)
                          .map((s) => s.unitId!)
                          .toSet();

                      final availableUnits = units
                          .where((u) => !assignedUnitIds.contains(u.id))
                          .toList();

                      if (availableUnits.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(16.0),
                          child: Text('No available units to assign. All units are already assigned to shapes.'),
                        );
                      }

                      return _UnitAssignmentDialogContent(
                        key: ValueKey(shape.id),
                        facilityId: widget.facilityId,
                        shapeId: shape.id,
                        availableUnits: availableUnits,
                        currentUnitId: shape.unitId,
                      );
                    },
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Text('Error loading shapes: $e'),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Error loading units: $e'),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showShapeActions(MapShapeModel shape, UnitModel? unit) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Assign Unit'),
              onTap: () {
                Navigator.of(context).pop();
                _showUnitAssignmentDialog(shape);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Duplicate Shape'),
              onTap: () {
                Navigator.of(context).pop();
                _selectShape(shape.id);
                _duplicateSelectedShape();
              },
            ),
            if (unit != null) ...[
              ListTile(
                leading: const Icon(Icons.info),
                title: const Text('View Unit Details'),
                onTap: () {
                  Navigator.of(context).pop();
                  _showUnitDetails(unit);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_location),
                title: const Text('Edit Unit'),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push(
                    AppRoute.legacyScreen,
                    extra: UnitCreationScreen(
                      facilityId: widget.facilityId,
                      unit: unit,
                    ),
                  );
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.delete, color: AppTheme.error),
              title: const Text('Delete Shape', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.of(context).pop();
                _deleteSelectedShape();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openShapeManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final shapesAsync = ref.watch(facilityMapShapesProvider(widget.facilityId));
          final unitsAsync = ref.watch(facilityUnitsProvider(widget.facilityId));
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.72,
            child: shapesAsync.when(
              data: (shapes) => unitsAsync.when(
                data: (units) {
                  final unitMap = {for (final u in units) u.id: u};
                  final sorted = [...shapes]..sort((a, b) => a.id.compareTo(b.id));
                  if (sorted.isEmpty) {
                    return const Center(child: Text('No shapes found'));
                  }
                  return Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Shape Manager',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          itemCount: sorted.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final shape = sorted[i];
                            final unit = shape.unitId == null ? null : unitMap[shape.unitId];
                            return ListTile(
                              dense: true,
                              title: Text(
                                unit != null
                                    ? 'Unit ${unit.unitNumber}'
                                    : 'Unassigned (${shape.id.substring(0, 6)})',
                              ),
                              subtitle: Text(
                                'x:${shape.x.toStringAsFixed(0)} y:${shape.y.toStringAsFixed(0)} '
                                'w:${shape.width.toStringAsFixed(0)} h:${shape.height.toStringAsFixed(0)}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.center_focus_strong),
                                    tooltip: 'Focus',
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                      _zoomToShape(shape);
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, color: AppTheme.error),
                                    tooltip: 'Delete',
                                    onPressed: () async {
                                      await MapLayoutService.deleteMapShape(
                                        facilityId: widget.facilityId,
                                        shapeId: shape.id,
                                      );
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Shape deleted'),
                                          duration: Duration(seconds: 1),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error loading units: $e')),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error loading shapes: $e')),
            ),
          );
        },
      ),
    );
  }

  String _formatUnitDisplay(UnitModel unit) {
    // Format: "301 / 10x10" or just "301" if no size
    final unitNumber = unit.unitNumber;
    final size = _getUnitSize(unit);
    if (size != null && size.isNotEmpty) {
      return '$unitNumber / $size';
    }
    return unitNumber;
  }

  String? _getUnitSize(UnitModel unit) {
    // Try to get size from dimensions first
    if (unit.dimensions != null) {
      final width = unit.dimensions!['width'];
      final depth = unit.dimensions!['depth'];
      // Use width × depth for storage units (not width × height)
      if (width != null && depth != null) {
        // If dimensions are in inches (large numbers), convert to feet
        // Storage units are typically 5-20 feet, so if > 50, assume inches
        final widthValue = width is num ? width.toDouble() : double.tryParse(width.toString()) ?? 0;
        final depthValue = depth is num ? depth.toDouble() : double.tryParse(depth.toString()) ?? 0;
        
        if (widthValue > 50 || depthValue > 50) {
          // Likely in inches, convert to feet and round
          final widthFt = (widthValue / 12).round();
          final depthFt = (depthValue / 12).round();
          return '${widthFt}x${depthFt}';
        } else {
          // Already in feet, format as-is
          return '${widthValue.toStringAsFixed(0)}x${depthValue.toStringAsFixed(0)}';
        }
      }
      // Fallback: try width × height if depth is not available
      final height = unit.dimensions!['height'];
      if (width != null && height != null) {
        final widthValue = width is num ? width.toDouble() : double.tryParse(width.toString()) ?? 0;
        final heightValue = height is num ? height.toDouble() : double.tryParse(height.toString()) ?? 0;
        
        if (widthValue > 50 || heightValue > 50) {
          // Likely in inches, convert to feet
          final widthFt = (widthValue / 12).round();
          final heightFt = (heightValue / 12).round();
          return '${widthFt}x${heightFt}';
        } else {
          return '${widthValue.toStringAsFixed(0)}x${heightValue.toStringAsFixed(0)}';
        }
      }
    }
    // Try to get size from description
    if (unit.description != null && unit.description!.isNotEmpty) {
      // Check if description contains size pattern like "10x10", "5x5", etc.
      final sizeMatch = RegExp(r'(\d+x\d+)', caseSensitive: false).firstMatch(unit.description!);
      if (sizeMatch != null) {
        return sizeMatch.group(1);
      }
    }
    return null;
  }

  Color _getUnitStatusColor(UnitStatus status) {
    switch (status) {
      case UnitStatus.available:
        return AppTheme.success;
      case UnitStatus.occupied:
        return AppTheme.primaryBlue;
      case UnitStatus.reserved:
        return AppTheme.warning;
      case UnitStatus.maintenance:
        return AppTheme.error;
      case UnitStatus.outOfOrder:
        return AppTheme.textTertiary;
      case UnitStatus.overlocked:
        return AppTheme.error;
      case UnitStatus.lockout:
        return AppTheme.error;
      case UnitStatus.auction:
        return AppTheme.warning;
    }
  }

  // Bulk operations handlers
  Future<void> _handleBulkStatusChange(List<String> unitIds, UnitStatus status) async {
    try {
      setState(() {
        _isSaving = true;
      });

      for (final unitId in unitIds) {
        await UnitService.updateUnit(
          facilityId: widget.facilityId,
          unitId: unitId,
          status: status,
        );
      }

      if (!mounted) return;
      setState(() {
        _selectedUnitIds.clear();
        _isSaving = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Updated ${unitIds.length} unit(s) to ${status.name}'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating units: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _handleBulkDelete() async {
    if (_selectedUnitIds.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No units selected for deletion'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    // Confirm deletion
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Selected Units'),
        content: Text(
          'Are you sure you want to delete ${_selectedUnitIds.length} unit(s) from the map? This will remove the map shapes. The units themselves will remain in the system unless you delete them separately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (mounted) {
      setState(() {
        _isSaving = true;
      });
    }

    try {
      // Get all map shapes to find which ones correspond to selected units
      final shapes = await MapLayoutService.getMapShapes(widget.facilityId);
      
      // Find shapes that match selected unit IDs
      final shapesToDelete = shapes
          .where((shape) => shape.unitId != null && _selectedUnitIds.contains(shape.unitId))
          .toList();

      if (shapesToDelete.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No map shapes found for selected units'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      // Delete all matching map shapes
      int successCount = 0;
      int failCount = 0;
      
      for (final shape in shapesToDelete) {
        try {
          await MapLayoutService.deleteMapShape(
            facilityId: widget.facilityId,
            shapeId: shape.id,
          );
          successCount++;
        } catch (e) {
          if (kDebugMode) {
            print('❌ Error deleting map shape ${shape.id}: $e');
          }
          failCount++;
        }
      }

      // Clear selection
      if (mounted) {
        setState(() {
          _selectedUnitIds.clear();
          _isBulkSelectMode = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failCount > 0
                  ? 'Deleted $successCount shape(s), $failCount failed'
                  : 'Successfully deleted $successCount map shape(s)',
            ),
            backgroundColor: failCount > 0 ? AppTheme.warning : AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error in bulk delete: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting units: ${ErrorMessageHelper.getUserFriendlyMessage(e)}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  // Map export/print functionality
  Future<void> _exportMap() async {
    try {
      setState(() {
        _isSaving = true;
      });

      // Capture the map as an image
      final image = await _captureMapImage();
      if (image == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to capture map image'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      // Get facility name for filename
      final facility = await FacilityService.getFacility(widget.facilityId);
      final facilityName = facility?.name ?? 'facility';
      final sanitizedName = facilityName.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final filename = '${sanitizedName}_map_$timestamp.png';

      // Convert image to PNG bytes
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to convert image to PNG'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      final pngBytes = byteData.buffer.asUint8List();

      // Web-safe download or file save
      if (kIsWeb) {
        try {
          map_export.downloadBytesAsFileWeb(pngBytes, filename);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Map exported as $filename'),
                backgroundColor: AppTheme.success,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        } catch (e) {
          if (kDebugMode) {
            print('❌ Error downloading map on web: $e');
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error exporting map: ${e.toString()}'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
        }
      } else {
        // Non-web platforms: This app is web-only, but keeping for completeness
        // On non-web, you would use path_provider and dart:io here
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Map export not available on this platform'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error exporting map: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error exporting map: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  Future<void> _printMap() async {
    try {
      setState(() {
        _isSaving = true;
      });

      // Capture the map as an image
      final image = await _captureMapImage();
      if (image == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to capture map image'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      // Get facility information
      final facility = await FacilityService.getFacility(widget.facilityId);
      final facilityName = facility?.name ?? 'Facility';
      
      // Convert image to PNG bytes
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to convert image to PNG'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      final pngBytes = byteData.buffer.asUint8List();

      // Create PDF with the map image
      final pdf = pw.Document();
      final imageWidth = image.width.toDouble();
      final imageHeight = image.height.toDouble();
      
      // Calculate page size to fit image (landscape orientation)
      final pageWidth = PdfPageFormat.letter.width;
      final pageHeight = PdfPageFormat.letter.height;
      
      // Scale image to fit page while maintaining aspect ratio
      final scale = (pageWidth / imageWidth).clamp(0.0, (pageHeight / imageHeight));
      final scaledWidth = imageWidth * scale;
      final scaledHeight = imageHeight * scale;

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.letter.landscape,
          build: (pw.Context context) {
            return pw.Column(
              children: [
                // Header
                pw.Header(
                  level: 0,
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        facilityName,
                        style: pw.TextStyle(
                          fontSize: 24,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        'Map - ${DateFormat('MM/dd/yyyy').format(DateTime.now())}',
                        style: const pw.TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 20),
                // Map image
                pw.Center(
                  child: pw.Image(
                    pw.MemoryImage(pngBytes),
                    width: scaledWidth,
                    height: scaledHeight,
                  ),
                ),
              ],
            );
          },
        ),
      );

      // Print/Share PDF
      await Printing.layoutPdf(
        onLayout: (format) async => pdf.save(),
        name: '${facilityName}_map_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Map PDF ready to print or save'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error printing map: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error printing map: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  /// Capture the map canvas as an image
  Future<ui.Image?> _captureMapImage() async {
    try {
      final renderObject = _mapCanvasKey.currentContext?.findRenderObject();
      if (renderObject == null) {
        if (kDebugMode) {
          print('❌ Render object not found for map canvas');
        }
        return null;
      }

      if (renderObject is! RenderRepaintBoundary) {
        if (kDebugMode) {
          print('❌ Render object is not a RepaintBoundary');
        }
        return null;
      }

      final image = await renderObject.toImage(pixelRatio: 2.0); // 2x for better quality
      return image;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error capturing map image: $e');
      }
      return null;
    }
  }
}

/// Grid painter for canvas background
class _GridPainter extends CustomPainter {
  final double gridSize;
  final Color color;
  final double offsetX;
  final double offsetY;

  _GridPainter({
    required this.gridSize,
    required this.color,
    this.offsetX = 0,
    this.offsetY = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0;

    // Calculate grid start positions accounting for offset
    final startX = (offsetX % gridSize) - gridSize;
    final startY = (offsetY % gridSize) - gridSize;

    for (double x = startX; x <= size.width; x += gridSize) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        paint,
      );
    }

    for (double y = startY; y <= size.height; y += gridSize) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) {
    return oldDelegate.gridSize != gridSize || 
           oldDelegate.color != color ||
           oldDelegate.offsetX != offsetX ||
           oldDelegate.offsetY != offsetY;
  }
}

/// Dialog content widget for unit assignment with proper state management
class _UnitAssignmentDialogContent extends StatefulWidget {
  final String facilityId;
  final String shapeId;
  final List<UnitModel> availableUnits;
  final String? currentUnitId;

  const _UnitAssignmentDialogContent({
    super.key,
    required this.facilityId,
    required this.shapeId,
    required this.availableUnits,
    this.currentUnitId,
  });

  @override
  State<_UnitAssignmentDialogContent> createState() => _UnitAssignmentDialogContentState();
}

class _UnitAssignmentDialogContentState extends State<_UnitAssignmentDialogContent> {
  String? _selectedUnitId;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedUnitId = widget.currentUnitId;
  }

  Future<void> _handleAssign() async {
    setState(() => _isSaving = true);
    try {
      if (_selectedUnitId != null) {
        await MapLayoutService.updateMapShape(
          facilityId: widget.facilityId,
          shapeId: widget.shapeId,
          unitId: _selectedUnitId,
        );
      } else {
        await MapLayoutService.updateMapShape(
          facilityId: widget.facilityId,
          shapeId: widget.shapeId,
          clearUnitId: true,
        );
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error assigning unit: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          value: _selectedUnitId,
          decoration: const InputDecoration(
            labelText: 'Select Unit',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('No unit assigned'),
            ),
            ...widget.availableUnits.map((unit) => DropdownMenuItem<String>(
                  value: unit.id,
                  child: Text('${unit.unitNumber} - ${unit.statusDisplayName}'),
                )),
          ],
          onChanged: _isSaving ? null : (value) {
            setState(() {
              _selectedUnitId = value;
            });
          },
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: _isSaving ? null : _handleAssign,
              child: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Assign'),
            ),
          ],
        ),
      ],
    );
  }
}
