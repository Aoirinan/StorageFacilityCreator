import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/unit_model.dart';
import '../theme/app_theme.dart';

class MapUnitTooltip extends StatelessWidget {
  final UnitModel unit;
  final VoidCallback? onViewDetails;
  final VoidCallback? onEdit;

  const MapUnitTooltip({
    super.key,
    required this.unit,
    this.onViewDetails,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getStatusColor(unit.status).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  unit.unitNumber,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _getStatusColor(unit.status),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  unit.statusDisplayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (unit.tenantName != null) ...[
            _buildInfoRow('Tenant', unit.tenantName!),
            const SizedBox(height: 4),
          ],
          _buildInfoRow('Rate', '\$${unit.monthlyRate.toStringAsFixed(2)}/month'),
          if (unit.moveInDate != null) ...[
            const SizedBox(height: 4),
            _buildInfoRow(
              'Move-In',
              DateFormat('MMM d, y').format(unit.moveInDate!),
            ),
          ],
          if (unit.description != null && unit.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              unit.description!,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (onViewDetails != null || onEdit != null) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onViewDetails != null)
                  TextButton(
                    onPressed: onViewDetails,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                    child: const Text('View Details'),
                  ),
                if (onEdit != null)
                  TextButton(
                    onPressed: onEdit,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                    child: const Text('Edit'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            '$label:',
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
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
}

