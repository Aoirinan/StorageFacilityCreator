import 'package:flutter/material.dart';
import '../services/late_logic_service.dart';

class BadgeWidget extends StatelessWidget {
  final BadgeInfo badgeInfo;
  final double? size;
  final bool showIcon;
  final bool showDescription;

  const BadgeWidget({
    super.key,
    required this.badgeInfo,
    this.size,
    this.showIcon = true,
    this.showDescription = false,
  });

  @override
  Widget build(BuildContext context) {
    final badgeSize = size ?? 20.0;
    final color = _getColorFromString(badgeInfo.color);
    final iconData = _getIconFromString(badgeInfo.icon);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: badgeSize * 0.3,
        vertical: badgeSize * 0.15,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(badgeSize * 0.3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon && iconData != null) ...[
            Icon(
              iconData,
              size: badgeSize * 0.6,
              color: color,
            ),
            SizedBox(width: badgeSize * 0.2),
          ],
          Text(
            badgeInfo.label,
            style: TextStyle(
              color: color,
              fontSize: badgeSize * 0.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Color _getColorFromString(String colorString) {
    switch (colorString.toLowerCase()) {
      case 'green':
        return Colors.green;
      case 'orange':
        return Colors.orange;
      case 'red':
        return Colors.red;
      case 'blue':
        return Colors.blue;
      case 'purple':
        return Colors.purple;
      case 'teal':
        return Colors.teal;
      case 'amber':
        return Colors.amber;
      case 'indigo':
        return Colors.indigo;
      default:
        return Colors.grey;
    }
  }

  IconData? _getIconFromString(String iconString) {
    switch (iconString) {
      case 'check_circle':
        return Icons.check_circle;
      case 'warning':
        return Icons.warning;
      case 'error':
        return Icons.error;
      case 'dangerous':
        return Icons.dangerous;
      case 'info':
        return Icons.info;
      case 'star':
        return Icons.star;
      case 'schedule':
        return Icons.schedule;
      case 'payment':
        return Icons.payment;
      case 'description':
        return Icons.description;
      case 'business':
        return Icons.business;
      case 'people':
        return Icons.people;
      default:
        return null;
    }
  }
}

class StatusBadge extends StatelessWidget {
  final String status;
  final String? color;
  final double? size;

  const StatusBadge({
    super.key,
    required this.status,
    this.color,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final badgeInfo = _getBadgeInfoFromStatus(status, color);
    return BadgeWidget(
      badgeInfo: badgeInfo,
      size: size,
    );
  }

  BadgeInfo _getBadgeInfoFromStatus(String status, String? color) {
    final statusLower = status.toLowerCase();
    final badgeColor = color ?? _getDefaultColor(statusLower);
    
    return BadgeInfo(
      label: status,
      color: badgeColor,
      icon: _getDefaultIcon(statusLower),
      description: 'Status: $status',
    );
  }

  String _getDefaultColor(String status) {
    switch (status) {
      case 'current':
      case 'active':
      case 'completed':
      case 'paid':
        return 'green';
      case 'late':
      case 'pending':
      case 'warning':
        return 'orange';
      case 'overdue':
      case 'expired':
      case 'failed':
      case 'error':
        return 'red';
      case 'info':
      case 'new':
        return 'blue';
      default:
        return 'grey';
    }
  }

  String _getDefaultIcon(String status) {
    switch (status) {
      case 'current':
      case 'active':
      case 'completed':
      case 'paid':
        return 'check_circle';
      case 'late':
      case 'pending':
      case 'warning':
        return 'warning';
      case 'overdue':
      case 'expired':
      case 'failed':
      case 'error':
        return 'error';
      case 'info':
      case 'new':
        return 'info';
      default:
        return 'info';
    }
  }
}

class PaymentStatusBadge extends StatelessWidget {
  final String status;
  final bool isOverdue;
  final int? daysOverdue;
  final double? size;

  const PaymentStatusBadge({
    super.key,
    required this.status,
    this.isOverdue = false,
    this.daysOverdue,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final badgeInfo = _getPaymentBadgeInfo();
    return BadgeWidget(
      badgeInfo: badgeInfo,
      size: size,
    );
  }

  BadgeInfo _getPaymentBadgeInfo() {
    if (isOverdue) {
      if (daysOverdue != null && daysOverdue! > 30) {
        return const BadgeInfo(
          label: 'Severely Overdue',
          color: 'red',
          icon: 'dangerous',
          description: 'Payment is severely overdue',
        );
      } else if (daysOverdue != null && daysOverdue! > 15) {
        return const BadgeInfo(
          label: 'Overdue',
          color: 'red',
          icon: 'error',
          description: 'Payment is overdue',
        );
      } else {
        return const BadgeInfo(
          label: 'Late',
          color: 'orange',
          icon: 'warning',
          description: 'Payment is late',
        );
      }
    }

    switch (status.toLowerCase()) {
      case 'completed':
      case 'paid':
        return const BadgeInfo(
          label: 'Paid',
          color: 'green',
          icon: 'check_circle',
          description: 'Payment completed',
        );
      case 'pending':
        return const BadgeInfo(
          label: 'Pending',
          color: 'blue',
          icon: 'schedule',
          description: 'Payment pending',
        );
      case 'failed':
        return const BadgeInfo(
          label: 'Failed',
          color: 'red',
          icon: 'error',
          description: 'Payment failed',
        );
      case 'refunded':
        return const BadgeInfo(
          label: 'Refunded',
          color: 'purple',
          icon: 'refresh',
          description: 'Payment refunded',
        );
      default:
        return BadgeInfo(
          label: status,
          color: 'grey',
          icon: 'info',
          description: 'Payment status: $status',
        );
    }
  }
}

class ContractStatusBadge extends StatelessWidget {
  final DateTime expiresAt;
  final double? size;

  const ContractStatusBadge({
    super.key,
    required this.expiresAt,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final daysUntilExpiry = expiresAt.difference(now).inDays;
    
    BadgeInfo badgeInfo;
    if (daysUntilExpiry < 0) {
      badgeInfo = const BadgeInfo(
        label: 'Expired',
        color: 'red',
        icon: 'error',
        description: 'Contract has expired',
      );
    } else if (daysUntilExpiry <= 30) {
      badgeInfo = BadgeInfo(
        label: 'Expiring Soon',
        color: 'orange',
        icon: 'warning',
        description: 'Contract expires in $daysUntilExpiry days',
      );
    } else {
      badgeInfo = const BadgeInfo(
        label: 'Active',
        color: 'green',
        icon: 'check_circle',
        description: 'Contract is active',
      );
    }

    return BadgeWidget(
      badgeInfo: badgeInfo,
      size: size,
    );
  }
}
