/// Map layer types for organizing map elements
enum MapLayerType {
  units, // Unit shapes
  buildings, // Building outlines
  aisles, // Aisle paths
  parking, // Parking areas
  labels, // Text labels
  custom, // Custom layer
}

/// Map layer configuration
class MapLayer {
  final MapLayerType type;
  final String name;
  final bool visible;
  final int zIndex;
  final String? color;
  final double? opacity;

  const MapLayer({
    required this.type,
    required this.name,
    this.visible = true,
    this.zIndex = 0,
    this.color,
    this.opacity,
  });

  String get displayName {
    switch (type) {
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

  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'name': name,
      'visible': visible,
      'zIndex': zIndex,
      if (color != null) 'color': color,
      if (opacity != null) 'opacity': opacity,
    };
  }

  factory MapLayer.fromMap(Map<String, dynamic> map) {
    return MapLayer(
      type: MapLayerType.values.firstWhere(
        (t) => t.name == map['type'],
        orElse: () => MapLayerType.custom,
      ),
      name: map['name'] as String,
      visible: map['visible'] as bool? ?? true,
      zIndex: map['zIndex'] as int? ?? 0,
      color: map['color'] as String?,
      opacity: (map['opacity'] as num?)?.toDouble(),
    );
  }
}

