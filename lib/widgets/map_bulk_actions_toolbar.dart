import 'package:flutter/material.dart';
import '../models/unit_model.dart';
import '../theme/app_theme.dart';

/// Toolbar for bulk operations on selected map blocks (and linked units when present).
class MapBulkActionsToolbar extends StatelessWidget {
  /// Total map blocks selected (includes unassigned shapes).
  final int selectedBlockCount;
  /// Unit IDs among the selection (for status changes only).
  final List<String> selectedUnitIds;
  final VoidCallback onClearSelection;
  final Function(List<String>, UnitStatus) onBulkStatusChange;
  final VoidCallback onBulkDelete;

  const MapBulkActionsToolbar({
    super.key,
    required this.selectedBlockCount,
    required this.selectedUnitIds,
    required this.onClearSelection,
    required this.onBulkStatusChange,
    required this.onBulkDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedBlockCount <= 0) {
      return const SizedBox.shrink();
    }

    final unitCount = selectedUnitIds.length;
    final statusEnabled = unitCount > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue.withOpacity(0.1),
        border: Border(
          top: BorderSide(color: AppTheme.primaryBlue, width: 2),
          bottom: BorderSide(color: AppTheme.borderLight),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: AppTheme.primaryBlue, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              unitCount == selectedBlockCount
                  ? '$selectedBlockCount unit${selectedBlockCount == 1 ? '' : 's'} selected'
                  : '$selectedBlockCount block${selectedBlockCount == 1 ? '' : 's'} selected ($unitCount with units)',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.primaryBlue,
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Bulk Status Change (only when at least one linked unit is selected)
          PopupMenuButton<UnitStatus>(
            enabled: statusEnabled,
            tooltip: statusEnabled ? 'Change Status' : 'Select blocks linked to units to change status',
            itemBuilder: (context) => UnitStatus.values.map((status) {
              return PopupMenuItem(
                value: status,
                child: Text(_getStatusLabel(status)),
              );
            }).toList(),
            onSelected: (status) => onBulkStatusChange(selectedUnitIds, status),
            child: ElevatedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('Change Status'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: AppTheme.textOnDark,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Bulk Delete
          OutlinedButton.icon(
            icon: const Icon(Icons.delete, size: 18),
            label: const Text('Delete'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.error,
              side: BorderSide(color: AppTheme.error),
            ),
            onPressed: () => _confirmBulkDelete(context),
          ),
          const SizedBox(width: 16),
          // Clear Selection
          TextButton.icon(
            icon: const Icon(Icons.close, size: 18),
            label: const Text('Clear Selection'),
            onPressed: onClearSelection,
          ),
        ],
      ),
    );
  }

  void _confirmBulkDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Selected Units'),
        content: Text(
          'Are you sure you want to delete $selectedBlockCount map block${selectedBlockCount == 1 ? '' : 's'}? Shapes are removed from the map; linked units remain unless removed separately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              onBulkDelete();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
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

