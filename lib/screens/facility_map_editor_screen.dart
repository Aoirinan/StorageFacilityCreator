import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'dart:io' if (dart.library.html) 'dart:html' as html;
import '../utils/error_message_helper.dart';

/// Provider for map shapes stream (scoped by facilityId)
final facilityMapShapesProvider = StreamProvider.family<List<MapShapeModel>, String>((ref, facilityId) {
  return MapLayoutService.getMapShapesStream(facilityId).handleError((error, stackTrace) {
    if (kDebugMode) {
      print('❌ Map shapes stream error: $error');
    }
  });
});

/// Provider for selected shape state
final selectedMapShapeProvider = StateProvider<String?>((ref) => null);

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

class _FacilityMapEditorScreenState extends ConsumerState<FacilityMapEditorScreen>
    with AutomaticKeepAliveClientMixin {
  final TransformationController _transformationController = TransformationController();
  final GlobalKey _mapCanvasKey = GlobalKey(); // Key for RepaintBoundary to capture map
  bool _isDisposed = false;
  String? _selectedShapeId;
  bool _showGrid = true;
  bool _snapToGrid = true;
  double _gridSize = 20.0;
  bool _isSaving = false;
  Offset? _dragOffset;
  String? _draggingShapeId; // Track which shape is currently being dragged
  bool _isResizing = false; // Track if we're resizing instead of dragging
  Set<UnitStatus> _statusFilters = UnitStatus.values.toSet(); // Show all by default
  bool _showLegend = false;
  String? _hoveredUnitId;
  UnitModel? _selectedUnitForNavigation;
  Set<String> _selectedUnitIds = {}; // For bulk operations
  Set<MapLayerType> _visibleLayers = {MapLayerType.units}; // Visible layers
  bool _isBulkSelectMode = false; // Toggle for bulk selection mode

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
    }
  }

  void _clearDragState() {
    if (!mounted) return;
    setState(() {
      _dragOffset = null;
      _draggingShapeId = null;
      _isResizing = false;
    });
  }

  void _nudgeShape(double deltaX, double deltaY) {
    if (_selectedShapeId == null) return;

    final shapesAsync = ref.read(facilityMapShapesProvider(widget.facilityId));
    shapesAsync.whenData((shapes) {
      final selectedId = _selectedShapeId;
      if (selectedId == null) return;
      final shape = shapes.firstWhere((s) => s.id == selectedId, orElse: () => throw StateError('Shape not found'));
      final newX = (shape.x + deltaX).clamp(0.0, 2000.0 - shape.width);
      final newY = (shape.y + deltaY).clamp(0.0, 1500.0 - shape.height);

      MapLayoutService.updateMapShape(
        facilityId: widget.facilityId,
        shapeId: shape.id,
        x: newX,
        y: newY,
      );
    });
  }

  void _selectShape(String? shapeId) {
    setState(() {
      _selectedShapeId = shapeId;
      _dragOffset = null;
    });
    ref.read(selectedMapShapeProvider.notifier).state = shapeId;
  }

  Future<void> _addRectangle() async {
    try {
      await MapLayoutService.createMapShape(
        facilityId: widget.facilityId,
        type: 'rect',
        x: 400.0,
        y: 300.0,
        width: 100.0,
        height: 80.0,
      );

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
      child: ModernPageWrapper(
        title: 'Site Map',
        currentRoute: '/units/map',
        onNavigate: (route) {
          if (kDebugMode) {
            print('🧭 Map screen onNavigate called with route: $route');
          }
          if (route == '/units' || route == '/units/map') {
            // Already on map; ignore to avoid duplicate navigation
            return;
          }
          // Use go instead of navigateToRoute to ensure proper navigation
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && context.mounted) {
              context.go(route);
            }
          });
        },
        child: Column(
          children: [
            _buildToolbar(),
            const Divider(height: 1),
            MapFilterToolbar(
              selectedStatuses: _statusFilters,
              onStatusFilterChanged: (statuses) {
                setState(() {
                  _statusFilters = statuses;
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
                      data: (shapes) => unitsAsync.when(
                        data: (units) => _buildCanvas(shapes, units),
                        loading: () => const Center(child: CircularProgressIndicator()),
                        error: (e, _) => _buildError('Error loading units: $e'),
                      ),
                      loading: () => const Center(child: CircularProgressIndicator()),
                      error: (e, _) => _buildError('Error loading map: $e'),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: AppTheme.surface,
      child: Row(
        children: [
          ElevatedButton.icon(
            onPressed: _addRectangle,
            icon: const Icon(Icons.add_box, size: 20),
            label: const Text('Add Rectangle'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: () => setState(() => _showGrid = !_showGrid),
            icon: Icon(_showGrid ? Icons.grid_on : Icons.grid_off),
            tooltip: 'Toggle Grid',
            color: _showGrid ? AppTheme.primaryBlue : AppTheme.textSecondary,
          ),
          IconButton(
            onPressed: () => setState(() => _snapToGrid = !_snapToGrid),
            icon: Icon(_snapToGrid ? Icons.grid_3x3 : Icons.grid_off),
            tooltip: 'Snap to Grid',
            color: _snapToGrid ? AppTheme.primaryBlue : AppTheme.textSecondary,
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
            color: _isBulkSelectMode ? AppTheme.primaryBlue : AppTheme.textSecondary,
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
          const Spacer(),
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
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _zoomToShape(MapShapeModel shape) {
    // Calculate center of shape
    final centerX = shape.x + shape.width / 2;
    final centerY = shape.y + shape.height / 2;
    
    // Get current transformation
    final matrix = _transformationController.value;
    final scale = 2.0; // Zoom level
    
    // Calculate new position
    final newMatrix = Matrix4.identity()
      ..translate(-centerX * scale + MediaQuery.of(context).size.width / 2,
                  -centerY * scale + MediaQuery.of(context).size.height / 2)
      ..scale(scale);
    
    _transformationController.value = newMatrix;
  }

  Widget _buildCanvas(List<MapShapeModel> shapes, List<UnitModel> units) {
    try {
      final unitsMap = {for (var unit in units) unit.id: unit};
      
      // Filter shapes based on status filters
      final filteredShapes = shapes.where((shape) {
        if (shape.unitId == null) return true; // Show unassigned shapes
        final unit = unitsMap[shape.unitId];
        if (unit == null) return true;
        return _statusFilters.contains(unit.status);
      }).toList();

      return InteractiveViewer(
        transformationController: _transformationController,
        minScale: 0.1,
        maxScale: 4.0,
        boundaryMargin: const EdgeInsets.all(200),
        panEnabled: _draggingShapeId == null && !_isResizing,
        child: GestureDetector(
          // Handle clicks on empty canvas to deselect
          onTapDown: (details) {
            if (_isDisposed || !mounted) return;
            // Simple approach: if no shape was tapped (handled by shape's onTap), deselect
            if (_selectedShapeId != null) {
              // Use a small delay to allow shape taps to process first
              Future.microtask(() {
                if (mounted && _selectedShapeId != null) {
                  setState(() {
                    _selectedShapeId = null;
                  });
                }
              });
            }
          },
          child: Container(
            width: 2000,
            height: 1500,
            decoration: BoxDecoration(
              color: AppTheme.backgroundLight,
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: Stack(
              clipBehavior: Clip.none, // Allow resize handles to be visible outside container
              children: [
                if (_showGrid) _buildGrid(),
                ...filteredShapes.map((shape) => _buildShape(
                      shape,
                      unitsMap[shape.unitId],
                      shape.id == _selectedShapeId,
                    )),
              ],
            ),
          ),
        ),
      );
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[MapEditor] Map render error: $e\n$stack');
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Map is temporarily unavailable.',
            style: const TextStyle(color: Colors.redAccent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
  }

  Widget _buildGrid() {
    return CustomPaint(
      painter: _GridPainter(
        gridSize: _gridSize,
        color: AppTheme.borderLight.withOpacity(0.3),
      ),
      size: const Size(2000, 1500),
    );
  }

  Widget _buildShape(MapShapeModel shape, UnitModel? unit, bool isSelected) {
    final statusColor = unit != null ? _getUnitStatusColor(unit.status) : AppTheme.textTertiary;
    final borderColor = isSelected ? AppTheme.primaryBlue : statusColor;
    final borderWidth = isSelected ? 3.0 : 2.0;

    // Apply drag offset ONLY if this is the shape being dragged
    final isDragging = shape.id == _draggingShapeId && _dragOffset != null;
    final dragOffset = _dragOffset ?? Offset.zero;
    final displayX = shape.x + (isDragging ? dragOffset.dx : 0);
    final displayY = shape.y + (isDragging ? dragOffset.dy : 0);

    return Positioned(
      left: displayX,
      top: displayY,
      child: Listener(
        // Block pointer events from reaching InteractiveViewer when this shape is being dragged
        onPointerDown: (event) {
          if (_draggingShapeId == shape.id) {
            // Consume the event to prevent InteractiveViewer from handling it
          }
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
              // Normal mode: select shape and show details
              _selectShape(shape.id);
              if (unit != null) {
                _showUnitDetails(unit);
              } else {
                _showUnitAssignmentDialog(shape);
              }
            }
          },
          onLongPress: () {
            if (_isDisposed || !mounted) return;
            _selectShape(shape.id);
            _showShapeActions(shape, unit);
          },
          onPanStart: (details) {
            if (_isDisposed || !mounted) return;
            _selectShape(shape.id);
            setState(() {
              _draggingShapeId = shape.id;
              _dragOffset = Offset.zero;
              _isResizing = false;
            });
          },
          onPanUpdate: (details) {
            if (_isDisposed || !mounted) return;
            if (_draggingShapeId == shape.id && !_isResizing) {
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              
              setState(() {
                _dragOffset = Offset(
                  (_dragOffset?.dx ?? 0) + details.delta.dx / scale,
                  (_dragOffset?.dy ?? 0) + details.delta.dy / scale,
                );
              });
            }
          },
          onPanEnd: (details) {
            if (_isDisposed || !mounted) return;
          if (_draggingShapeId == shape.id && _dragOffset != null && !_isResizing) {
            final newX = (shape.x + _dragOffset!.dx).clamp(0.0, 2000.0 - shape.width);
            final newY = (shape.y + _dragOffset!.dy).clamp(0.0, 1500.0 - shape.height);

            if (_snapToGrid) {
              final snappedX = (newX / _gridSize).round() * _gridSize;
              final snappedY = (newY / _gridSize).round() * _gridSize;
              
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                x: snappedX.clamp(0.0, 2000.0 - shape.width),
                y: snappedY.clamp(0.0, 1500.0 - shape.height),
              );
            } else {
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                x: newX,
                y: newY,
              );
            }
          }
            _clearDragState();
        },
          onPanCancel: () => _clearDragState(),
        child: Stack(
          clipBehavior: Clip.none, // Allow resize handles outside bounds
          children: [
            MouseRegion(
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
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: shape.width,
                    height: shape.height,
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
                                    : AppTheme.primaryBlue).withOpacity(0.3),
                                blurRadius: 8,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
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
                            ),
                            Text(
                              unit.statusDisplayName,
                              style: TextStyle(
                                fontSize: 9,
                                color: statusColor,
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
                  if (_hoveredUnitId == unit?.id && unit != null)
                    Positioned(
                      // Position tooltip above the unit, ensuring it doesn't overlap with units above
                      top: -140,
                      left: 0,
                      right: 0,
                      child: Align(
                        alignment: Alignment.topCenter,
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
                ],
              ),
            ),
            // Resize handles - only show when selected and not dragging
            if (isSelected && _draggingShapeId == null)
              ..._buildResizeHandles(shape),
          ],
        ),
      ),
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
        top: -handleSize / 2,
        child: GestureDetector(
          onPanStart: (details) {
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (shape.width - deltaX).clamp(20.0, 2000.0);
              final newHeight = (shape.height - deltaY).clamp(20.0, 1500.0);
              final newX = (shape.x + deltaX).clamp(0.0, 2000.0 - newWidth);
              final newY = (shape.y + deltaY).clamp(0.0, 1500.0 - newHeight);
              
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                x: newX,
                y: newY,
                width: newWidth,
                height: newHeight,
              );
            }
          },
          onPanEnd: (details) {
            setState(() {
              _isResizing = false;
              _draggingShapeId = null;
            });
          },
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
        top: -handleSize / 2,
        child: GestureDetector(
          onPanStart: (details) {
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (shape.width + deltaX).clamp(20.0, 2000.0 - shape.x);
              final newHeight = (shape.height - deltaY).clamp(20.0, 1500.0);
              final newY = (shape.y + deltaY).clamp(0.0, 1500.0 - newHeight);
              
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                y: newY,
                width: newWidth,
                height: newHeight,
              );
            }
          },
          onPanEnd: (details) {
            setState(() {
              _isResizing = false;
              _draggingShapeId = null;
            });
          },
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
          onPanStart: (details) {
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (shape.width - deltaX).clamp(20.0, 2000.0);
              final newHeight = (shape.height + deltaY).clamp(20.0, 1500.0 - shape.y);
              final newX = (shape.x + deltaX).clamp(0.0, 2000.0 - newWidth);
              
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                x: newX,
                width: newWidth,
                height: newHeight,
              );
            }
          },
          onPanEnd: (details) {
            setState(() {
              _isResizing = false;
              _draggingShapeId = null;
            });
          },
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
          onPanStart: (details) {
            setState(() {
              _isResizing = true;
              _draggingShapeId = shape.id;
            });
          },
          onPanUpdate: (details) {
            if (_isResizing && _draggingShapeId == shape.id) {
              final matrix = _transformationController.value;
              final scale = matrix.getMaxScaleOnAxis();
              final deltaX = details.delta.dx / scale;
              final deltaY = details.delta.dy / scale;
              
              final newWidth = (shape.width + deltaX).clamp(20.0, 2000.0 - shape.x);
              final newHeight = (shape.height + deltaY).clamp(20.0, 1500.0 - shape.y);
              
              MapLayoutService.updateMapShape(
                facilityId: widget.facilityId,
                shapeId: shape.id,
                width: newWidth,
                height: newHeight,
              );
            }
          },
          onPanEnd: (details) {
            setState(() {
              _isResizing = false;
              _draggingShapeId = null;
            });
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeDownRight,
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
        // Use browser download API for web
        // Note: html is available via conditional import when on web
        try {
          final blob = html.Blob([pngBytes]);
          final url = html.Url.createObjectUrlFromBlob(blob);
          final anchor = html.AnchorElement(href: url)
            ..setAttribute('download', filename)
            ..click();
          html.Url.revokeObjectUrl(url);
          
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

  _GridPainter({
    required this.gridSize,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0;

    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        paint,
      );
    }

    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) {
    return oldDelegate.gridSize != gridSize || oldDelegate.color != color;
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
