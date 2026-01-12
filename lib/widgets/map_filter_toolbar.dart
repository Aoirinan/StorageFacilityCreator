import 'package:flutter/material.dart';
import '../models/unit_model.dart';
import '../theme/app_theme.dart';

class MapFilterToolbar extends StatelessWidget {
  final Set<UnitStatus> selectedStatuses;
  final ValueChanged<Set<UnitStatus>> onStatusFilterChanged;
  final bool showLegend;
  final VoidCallback onToggleLegend;

  const MapFilterToolbar({
    super.key,
    required this.selectedStatuses,
    required this.onStatusFilterChanged,
    this.showLegend = false,
    required this.onToggleLegend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Row(
        children: [
          const Text(
            'Filter:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          _buildFilterChip('All', UnitStatus.values.toSet(), selectedStatuses.length == UnitStatus.values.length),
          const SizedBox(width: 8),
          ...UnitStatus.values.map((status) => Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: _buildStatusFilterChip(status),
              )),
          const Spacer(),
          IconButton(
            icon: Icon(showLegend ? Icons.info : Icons.info_outline),
            onPressed: onToggleLegend,
            tooltip: 'Toggle Legend',
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, Set<UnitStatus> statuses, bool isSelected) {
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          onStatusFilterChanged(statuses);
        } else {
          onStatusFilterChanged({});
        }
      },
      selectedColor: AppTheme.primaryBlue.withOpacity(0.2),
      checkmarkColor: AppTheme.primaryBlue,
    );
  }

  Widget _buildStatusFilterChip(UnitStatus status) {
    final isSelected = selectedStatuses.contains(status);
    final color = _getStatusColor(status);

    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(_getStatusLabel(status)),
        ],
      ),
      selected: isSelected,
      onSelected: (selected) {
        final newStatuses = Set<UnitStatus>.from(selectedStatuses);
        if (selected) {
          newStatuses.add(status);
        } else {
          newStatuses.remove(status);
        }
        onStatusFilterChanged(newStatuses);
      },
      selectedColor: color.withOpacity(0.2),
      checkmarkColor: color,
    );
  }

  Color _getStatusColor(UnitStatus status) {
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
        return Colors.grey;
      case UnitStatus.overlocked:
        return Colors.red;
      case UnitStatus.lockout:
        return Colors.red;
      case UnitStatus.auction:
        return Colors.orange;
    }
  }

  String _getStatusLabel(UnitStatus status) {
    switch (status) {
      case UnitStatus.available:
        return 'Available';
      case UnitStatus.occupied:
        return 'Occupied';
      case UnitStatus.reserved:
        return 'Reserved';
      case UnitStatus.maintenance:
        return 'Maintenance';
      case UnitStatus.outOfOrder:
        return 'Out of Order';
      case UnitStatus.overlocked:
        return 'Overlocked';
      case UnitStatus.lockout:
        return 'Lockout';
      case UnitStatus.auction:
        return 'Auction';
    }
  }
}

