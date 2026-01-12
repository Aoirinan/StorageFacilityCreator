import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/email_usage_service.dart';

/// Widget to display email usage with progress bar and warnings
class EmailUsageCard extends ConsumerWidget {
  final String facilityId;
  final bool showDetails;

  const EmailUsageCard({
    super.key,
    required this.facilityId,
    this.showDetails = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<EmailUsage>(
      stream: EmailUsageService.streamEmailUsage(facilityId),
      initialData: EmailUsage.placeholder(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Error loading email usage',
                      style: TextStyle(color: Colors.red[700]),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final usage = snapshot.data ?? EmailUsage.placeholder();
        final percentage = usage.percentage;
        final isWarning = percentage >= 80 && percentage < 100;
        final isError = percentage >= 100;

        Color progressColor;
        if (isError) {
          progressColor = Colors.red;
        } else if (isWarning) {
          progressColor = Colors.orange;
        } else {
          progressColor = Colors.green;
        }

        return Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.email,
                      color: progressColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Email Usage',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (isWarning || isError)
                      Icon(
                        isError ? Icons.error : Icons.warning,
                        color: isError ? Colors.red : Colors.orange,
                        size: 16,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                
                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: percentage / 100,
                    backgroundColor: Colors.grey[200],
                    valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 8),
                
                // Usage text
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${usage.currentCount} / ${usage.monthlyLimit} emails',
                      style: TextStyle(
                        fontSize: 14,
                        color: isError ? Colors.red[700] : 
                               isWarning ? Colors.orange[700] : Colors.grey[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '${percentage.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 14,
                        color: isError ? Colors.red[700] : 
                               isWarning ? Colors.orange[700] : Colors.grey[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                
                // Warning message
                if (isWarning || isError) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isError ? Colors.red[50] : Colors.orange[50],
                      border: Border.all(
                        color: isError ? Colors.red[200]! : Colors.orange[200]!,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isError ? Icons.error_outline : Icons.warning_amber_outlined,
                          color: isError ? Colors.red[700] : Colors.orange[700],
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isError 
                              ? 'Email limit reached! No more emails can be sent this month.'
                              : 'Email usage is high. Consider upgrading your plan.',
                            style: TextStyle(
                              fontSize: 12,
                              color: isError ? Colors.red[700] : Colors.orange[700],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                
                // Additional details
                if (showDetails) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Monthly limit resets on the 1st of each month',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Compact email usage indicator for smaller spaces
class EmailUsageIndicator extends ConsumerWidget {
  final String facilityId;

  const EmailUsageIndicator({
    super.key,
    required this.facilityId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<EmailUsage>(
      stream: EmailUsageService.streamEmailUsage(facilityId),
      initialData: EmailUsage.placeholder(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _EmailUsageStatusChip(
            icon: Icons.error_outline,
            label: 'Email usage unavailable',
            color: Colors.orange,
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting && snapshot.data == null) {
          return _EmailUsageStatusChip(
            icon: Icons.downloading,
            label: 'Loading email usage…',
            color: Colors.blueGrey,
            showSpinner: false,
          );
        }

        final usage = snapshot.data ?? EmailUsage.placeholder();
        final limit = usage.monthlyLimit <= 0 ? 1000 : usage.monthlyLimit;
        final percentage = (usage.currentCount / limit).clamp(0, 1) * 100;
        final isWarning = percentage >= 80 && percentage < 100;
        final isError = percentage >= 100;

        Color color;
        if (isError) {
          color = Colors.red;
        } else if (isWarning) {
          color = Colors.orange;
        } else {
          color = Colors.green;
        }

        return _EmailUsageStatusChip(
          icon: Icons.email_outlined,
          label: '${usage.currentCount}/$limit emails this month',
          color: color,
        );
      },
    );
  }
}

class _EmailUsageStatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool showSpinner;

  const _EmailUsageStatusChip({
    required this.icon,
    required this.label,
    required this.color,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (showSpinner) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
