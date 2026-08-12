import 'package:flutter/material.dart';
import '../models/unit_model.dart';
import '../theme/app_theme.dart';

class MapLegend extends StatelessWidget {
  const MapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text(
                  'Unit Status Legend',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...UnitStatus.values.map((status) => _buildLegendItem(context, status)),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(BuildContext context, UnitStatus status) {
    final color = _getStatusColor(status);
    final label = _getStatusLabel(status);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              border: Border.all(color: color, width: 2),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
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
        return Colors.deepPurple;
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
        return 'Available - Unit is ready for rent';
      case UnitStatus.occupied:
        return 'Occupied - Unit has an active tenant';
      case UnitStatus.reserved:
        return 'Reserved - Unit is reserved for upcoming move-in';
      case UnitStatus.maintenance:
        return 'Maintenance - Unit is being serviced';
      case UnitStatus.outOfOrder:
        return 'Out of Order - Unit is not available';
      case UnitStatus.overlocked:
        return 'Overlocked - Unit is locked due to delinquency';
      case UnitStatus.lockout:
        return 'Lockout - Unit is locked out';
      case UnitStatus.auction:
        return 'Auction - Unit is in auction process';
    }
  }
}

