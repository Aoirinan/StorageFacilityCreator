import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum ReportType {
  financial,
  arAging,
  occupancy,
  delinquency,
  deposits,
}

class ReportTypeSelector extends StatelessWidget {
  final ReportType selectedType;
  final Function(ReportType) onTypeSelected;

  const ReportTypeSelector({
    super.key,
    required this.selectedType,
    required this.onTypeSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Report Type',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ReportType.values.map((type) {
              return FilterChip(
                label: Text(_getTypeLabel(type)),
                selected: selectedType == type,
                onSelected: (selected) {
                  if (selected) {
                    onTypeSelected(type);
                  }
                },
                selectedColor: AppTheme.primaryBlue.withOpacity(0.2),
                checkmarkColor: AppTheme.primaryBlue,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  String _getTypeLabel(ReportType type) {
    switch (type) {
      case ReportType.financial:
        return 'Financial';
      case ReportType.arAging:
        return 'AR Aging';
      case ReportType.occupancy:
        return 'Occupancy';
      case ReportType.delinquency:
        return 'Delinquency';
      case ReportType.deposits:
        return 'Deposits';
    }
  }

  IconData _getTypeIcon(ReportType type) {
    switch (type) {
      case ReportType.financial:
        return Icons.attach_money;
      case ReportType.arAging:
        return Icons.account_balance_wallet;
      case ReportType.occupancy:
        return Icons.business;
      case ReportType.delinquency:
        return Icons.warning;
      case ReportType.deposits:
        return Icons.account_balance;
    }
  }
}

